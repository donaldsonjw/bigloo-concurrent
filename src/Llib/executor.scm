;;; -*- mode:bee; coding:utf-8 -*-
;;;
;;; util/concurrent/executor.scm - Concurrent executor
;;;
;;;   Port To Bigloo
;;;   Copyright (c) 2020 Joseph Donaldson <donaldsonjw@gmail.com>
;;;
;;;   Original Scheme Implementation
;;;   Copyright (c) 2010-2014  Takashi Kato  <ktakashi@ymail.com>
;;;   
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;  
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;  
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;
(module bigloo-concurrent/executor
   (include "exception-compat.sch")
   (library pthread srfi117)
   (import bigloo-concurrent/future)
   (import bigloo-concurrent/thread-pool)
   (export
      (class &assertion::&exception
         who
         msg
         irritant)
      (class &rejected-execution-error::&error
         future
         executor)
      (final-class &duplicate-executor-registration::&error)
      (class <executor-future>::<future>)
      (abstract-class <executor>
         (state::symbol (default 'running)))
      (class <thread-pool-executor>::<executor>
         (pool-ids read-only)
         (pool read-only)
         (rejected-handler read-only)
         (mutex read-only (default (make-mutex))))
      (class <fork-join-executor>::<executor>)      
      (inline executor? v)
      (generic shutdown-executor! e::<executor>)
      (generic execute-future! e::<executor> f)
      (generic executor-available? e::<executor>)
      (executor-submit! e thunk)
      (make-thread-pool-executor max-pool-size::long #!optional (rejected-handler default-rejected-handler))
      (inline thread-pool-executor? v)
      (thread-pool-executor-pool-size executor)
      (thread-pool-executor-max-pool-size executor)
      (abort-rejected-handler future executor)
      (terminate-oldest-handler future executor)
      (wait-finishing-handler wait-retry)
      (push-future-handler future executor)
      (make-fork-join-executor)
      (fork-join-executor? v)
      (make-executor-future thunk::procedure)
      (executor-future? v)
      (inline executor-state ex::<executor>)
      default-rejected-handler))

;;;; macros
(define-syntax with-atomic
    (syntax-rules ()
      ((_ executor expr ...)
       (dynamic-wind
	   (lambda () (mutex-lock-recursively! (executor-mutex executor)))
	   (lambda () expr ...)
	   (lambda () (mutex-unlock-recursively! (executor-mutex executor)))))))


;;;; utilities
(define (assertion-violation who msg irritant)
   (raise (instantiate::&assertion (who who) (msg msg) (irritant irritant))))

;; mutex-state has different behavior in the pthread and java
;; backends for the bigloo threads library. The pthread backend
;; returns 'locked or 'unlocked from mutex-state whereas the java
;; backend returns either the thread when locked or 'not-abandoned
;; when not locked or 'abandoned if it has been abandoned by its owning thread
(define-inline (mutex-locked? m)
   (let ((state (mutex-state m)))
      (or (eq? 'locked state)
          (not (symbol? state)))))
(cond-expand
   (bigloo-c
    (define-inline (mutex-lock-recursively! mutex)
       (mutex-lock! mutex))
    (define (mutex-unlock-recursively! mutex)
       (mutex-unlock! mutex)))
   (bigloo-jvm
    (define-inline (mutex-lock-recursively! mutex)
       (let ((p (mutex-specific mutex)))
          (if (and (mutex-locked? mutex)
                   (and (pair? p)
                        (eq? (car p) (current-thread))))
              (let ((n (cdr p)))
                 (set-cdr! p (+ n 1)))
              (begin
                 (mutex-lock! mutex)
                 (mutex-specific-set! mutex (cons (current-thread) 0))))))
    
    (define-inline (mutex-unlock-recursively! mutex)
       (let* ((p (mutex-specific mutex))
              (n (cdr p)))
          (set-cdr! p (- n 1))
                 (when (= n 0)
             (mutex-unlock! mutex))))))

;;;; executor
(define-inline (executor? v)
   (isa? v <executor>))

(define-inline (executor-state ex::<executor>)
   (-> ex state))

(define-inline (executor-state-set! ex::<executor> v::symbol)
   (set! (-> ex state) v))

(define-generic (executor-available? e::<executor>))

(define-generic (execute-future! e::<executor> f))

(define-generic (shutdown-executor! e::<executor>))

(define (not-started . dummy)
   (assertion-violation 'executor-future "Future is not started yet" dummy))

(define (make-executor-future thunk::procedure)
   (instantiate::<executor-future> (thunk thunk)
                                   (result not-started)
                                   (state 'created)
                                   (canceller #f)))

(define (executor-future? v)
   (isa? v <executor-future>))

(define (make-thread-pool-executor max-pool-size::long #!optional (rejected-handler default-rejected-handler))
   (instantiate::<thread-pool-executor> (pool-ids (make-list-queue '()))
                                        (pool (make-thread-pool max-pool-size))
                                        (rejected-handler rejected-handler)))

(define-inline (thread-pool-executor? v)
   (isa? v <thread-pool-executor>))

(define-inline (executor-mutex ex::<thread-pool-executor>)
   (-> ex mutex))

(define-inline (executor-pool ex::<thread-pool-executor>)
   (-> ex pool))

(define-inline (executor-pool-ids ex::<thread-pool-executor>)
   (-> ex pool-ids))

;; TODO some other reject policy
;; aboring when pool is full
(define (abort-rejected-handler future executor)
   (raise (instantiate::&rejected-execution-error
             (proc 'executor)
             (msg "Failed to add task")
             (future future)
             (executor executor)
             (obj #f))))

;; assume the oldest one is negligible
(define (terminate-oldest-handler future executor)
   (define (get-oldest executor)
      (with-atomic executor
         (let ((l (executor-pool-ids executor)))
            (and (not (list-queue-empty? l))
                 (list-queue-remove-front! l)))))
   ;; the oldest might already be finished.
   (let ((oldest (get-oldest executor)))
      (and oldest
	   ;; if the running future is finishing and locking the mutex,
	   ;; we'd get abandoned mutex. to avoid it lock it.
	   (with-atomic executor
              (thread-pool-thread-terminate! (executor-pool executor)
                 (car oldest)))
	   (cleanup executor (cdr oldest) 'terminated)))
   ;; retry
   (execute-future! executor future))

;; wait for trivial time until pool is available
;; if it won't then raise an error.
(define (wait-finishing-handler wait-retry)
   (lambda (future executor)
      (thread-sleep! 0.1) ;; trivial time waiting
      (let loop ((count 0))
         (cond ((executor-available? executor)
                (execute-future! executor future))
               ((= count wait-retry)
                ;; now how should we handle this?
                ;; for now raises an error...
                (abort-rejected-handler future executor))
               ;; bit longer waiting
               (else (thread-sleep! 0.5) (loop (+ count 1)))))))

;; default is abort
(define default-rejected-handler abort-rejected-handler)

;; For now only dummy
; (define-record-type (<executor> %make-executor executor?)
;    (fields (mutable state executor-state executor-state-set!))
;    (protocol (lambda (p) (lambda () (p 'running)))))

(define (thread-pool-executor-pool-size executor)
   (length (list-queue-list (executor-pool-ids executor))))

(define (thread-pool-executor-max-pool-size executor)
   (thread-pool-size (executor-pool executor)))

(define (cleanup executor future state)
   (define (remove-from-queue! proc queue)
      (list-queue-set-list! queue (filter! (lambda (x) (not (proc x)))
                                     (list-queue-list queue))))
   (with-atomic executor
      (remove-from-queue! (lambda (o) (eq? (cdr o) future))
         (executor-pool-ids executor))
      (future-state-set! future state)))

(define-method (executor-available? executor::<thread-pool-executor>)
   (< (thread-pool-executor-pool-size executor) 
      (thread-pool-executor-max-pool-size executor)))

;; shutdown
(define-method (shutdown-executor! executor::<thread-pool-executor>)
   ;; executor-future's future-cancel uses with-atomic
   ;; so first finish up what we need to do for the executor
   ;; then call future-cancel.
   (define (executor-shutdown executor)
      (with-atomic executor
         (let ((state (executor-state executor)))
            (guard (e (else (executor-state-set! executor state)
                            (raise e)))
               ;; to avoid accepting new task
               ;; chenge it here
               (when (eq? state 'running)
                  (executor-state-set! executor 'shutdown))
               ;; we terminate the threads so that we can finish all
               ;; infinite looped threads.
               ;; NB, it's dangerous
               (thread-pool-release! (executor-pool executor) 'terminate)
               (list-queue-remove-all! (executor-pool-ids executor))))))
   ;; now cancel futures
   (for-each (lambda (future) (future-cancel (cdr future)))
      (executor-shutdown executor))
   #t)

(define-method (execute-future! executor::<thread-pool-executor> future)
   (or (with-atomic executor
	  (let ((pool-size (thread-pool-executor-pool-size executor))
		(max-pool-size (thread-pool-executor-max-pool-size
                                  executor)))
             (and (< pool-size max-pool-size)
                  (eq? (executor-state executor) 'running)
                  (push-future-handler future executor))))
       ;; the reject handler may lock executor again
       ;; to avoid double lock, this must be out side of atomic
       ((-> executor rejected-handler) future executor)))

;; We can push the future to thread-pool
(define (push-future-handler future executor)
   (define (canceller future) (cleanup executor future 'terminated))
   (define (task-invoker thunk)
      (lambda ()
         (let ((q (future-result future)))
            (guard (e (else
                       (future-canceller-set! future #t) ;; kinda abusing
                       (cleanup executor future 'finished)
                       (shared-box-put! q e)))
               (let ((r (thunk)))
                  ;; first remove future then put the result
                  ;; otherwise future-get may be called before.
                  (cleanup executor future 'finished)
                  (shared-box-put! q r))))))
   (define (add-future future executor)
      (future-result-set! future (make-shared-box))    
      (let* ((thunk (future-thunk future))
	     (id (thread-pool-push-task! (executor-pool executor)
                    (task-invoker thunk))))
         (future-canceller-set! future canceller)
         (list-queue-add-back! (executor-pool-ids executor) (cons id future))
         
         executor))
   ;; in case this is called directly
   (unless (eq? (executor-state executor) 'running)
      (assertion-violation 'push-future-handler
         "executor is not running" executor))
   (with-atomic executor (add-future future executor)))

(define (make-fork-join-executor)
   (instantiate::<fork-join-executor>))

(define (fork-join-executor? v)
   (isa? v <fork-join-executor>))

(define-method (executor-available? e::<fork-join-executor>) 
   #t)

(define-method (execute-future! e::<fork-join-executor> f)
   ;; the same as simple future
   (define (task-invoker thunk)
      (lambda ()
         (let ((q (future-result f)))
            (guard (e (else (future-canceller-set! f #t)
                            (future-state-set! f 'finished)
                            (shared-box-put! q e)))
               (let ((r (thunk)))
                  (future-state-set! f 'finished)
                  (shared-box-put! q r))))))
   (unless (fork-join-executor? e)
      (assertion-violation 'fork-join-executor-available? 
         "not a fork-join-executor" e))
   (unless (shared-box? (future-result f))
      (future-result-set! f (make-shared-box)))
   ;; we don't manage thread so just create and return
   (thread-start-joinable! (make-thread (task-invoker (future-thunk f))))
   f)

(define-method (shutdown-executor! e::<fork-join-executor>)
   ;; we don't manage anything
   (executor-state-set! e 'shutdown))


(define (not-supported e)
   (error #f "given executor is not supported" e))

(define (executor-submit! e thunk)
   (let ((f (make-executor-future thunk)))
      (execute-future! e f)
      f))