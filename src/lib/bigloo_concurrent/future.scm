;;; -*- mode:bee; coding:utf-8 -*-
;;;
;;; util/concurrent/future.scm - Future
;;;
;;;   Port To Bigloo
;;;   Copyright (c) 2020 Joseph Donaldson <donaldsonjw@gmail.com>
;;;
;;;   Original Scheme Implementation
;;;   Copyright (c) 2010-2015  Takashi Kato  <ktakashi@ymail.com>
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
(module bigloo-concurrent/future
   (include "exception-compat.sch")
   (library pthread)
   (static
      (class <shared-box>
         value
         (lock read-only (default (make-mutex)))
         (cv read-only (default (make-condition-variable)))))
   
   (export
      (class &future-terminated::&error)
      (class <future>
         thunk::procedure
         result
         (state::symbol (default 'created))
         (canceller (default #f))
         (mutex (default (make-mutex))))
      (class <simple-future>::<future>)
      (future? v)
      (future-get future::<future> . opt)
      (future-cancel future::<future>)
      (future-done? future::<future>)
      (future-cancelled? future::<future>)
      (inline future-terminated? v)
      (inline future-state f::<future>)
      (inline future-state-set! f::<future> state::symbol)
      (inline future-thunk f::<future>)
      (inline future-result f::<future>)
      (inline future-result-set! f::<future> result)
      (inline future-canceller f::<future>)
      (inline future-canceller-set! f::<future> canceller)      
      (make-simple-future thunk::procedure)
      (inline simple-future? v)
      (shared-box-put! sb o)
      (shared-box-get! sb . maybe-timeout)
      (make-shared-box)
      (shared-box? v)))

;; lightweight shared-queue to retrieve future result
(define shared-box-mark (list 'shared-box))

(define (make-shared-box)
   (instantiate::<shared-box> (value shared-box-mark)))

(define (shared-box? v)
   (isa? v <shared-box>))

;;;; begin shared-box accessors matching original record type
(define-inline (%sb-value sb::<shared-box>)
   (-> sb value))

(define-inline (%sb-value-set! sb::<shared-box> v)
   (set! (-> sb value) v))

(define-inline (%sb-lock sb::<shared-box>)
   (-> sb lock))

(define-inline (%sb-cv sb::<shared-box>)
   (-> sb cv))
;;;; end shared box accessors

(define (shared-box-put! sb o)
   (synchronize (%sb-lock sb)
      (%sb-value-set! sb o)
      ;; TODO do we need count waiter?
      (condition-variable-broadcast! (%sb-cv sb))))

(define (shared-box-get! sb . maybe-timeout)
   (define timeout (if (pair? maybe-timeout) (car maybe-timeout) 0))
   (define timeout-value (if (and (pair? maybe-timeout)
				   (pair? (cdr maybe-timeout)))
			      (cadr maybe-timeout)
			      #f))
   (synchronize (%sb-lock sb)
      (let loop ()
       (let ((r (%sb-value sb)))
          (cond ((eq? r shared-box-mark)
                 (cond ((condition-variable-wait! (%sb-cv sb) (%sb-lock sb) timeout)
                        (loop))
                       (else
                        timeout-value)))
                (else 
                 r))))))


;; future
(define (%make-future thunk result)
   (instantiate::<future> (thunk thunk)
                          (result result)
                          (state 'created)
                          (canceller #f)))

(define (future? v)
   (isa? v <future>))

;;;; future accessors to match original record type
(define-inline (future-state f::<future>)
   (synchronize (-> f mutex)
      (-> f state)))

(define-inline (future-state-set! f::<future> state)
   (synchronize (-> f mutex)
      ;; don't overwrite a terminal state
      (unless (or (eq? (-> f state) 'terminated)
                  (eq? (-> f state) 'done))
         (set! (-> f state) state))))

(define-inline (future-thunk f::<future>)
   (-> f thunk))

(define-inline (future-result f::<future>)
   (synchronize (-> f mutex)
      (-> f result)))

(define-inline (future-result-set! f::<future> result)
   (synchronize (-> f mutex)
      (set! (-> f result) result)))

(define-inline (future-canceller f::<future>)
   (synchronize (-> f mutex)
      (-> f canceller)))

(define-inline (future-canceller-set! f::<future> canceller)
   (synchronize (-> f mutex)
      (set! (-> f canceller) canceller)))

;;;; end future accessors
(define (simple-invoke thunk f q)
   (lambda ()
      (guard (e (else (future-canceller-set! f #t)
		      (future-state-set! f 'finished)
		      (shared-box-put! q e)))
         (let ((r (thunk)))
            (let ((curr-thread::pthread (current-thread)))
               (cond ((isa? (-> curr-thread end-exception) terminated-thread-exception)
                      (future-state-set! f 'terminated))
                     (else
                      (future-state-set! f 'finished))))
            (shared-box-put! q r)))))

(define (make-simple-future thunk::procedure)
   (let* ((q (make-shared-box))
          (f (instantiate::<simple-future> (thunk thunk) (result q))))
      (thread-start-joinable! (make-thread (simple-invoke thunk f q)))
      f))

(define-inline (simple-future? v)
   (isa? v <simple-future>))

(define-inline (future-terminated? v)
   (isa? v &future-terminated))

(define (raise-future-terminated future)
   (raise (instantiate::&future-terminated
             (proc 'future-get)
             (msg "future is terminated")
             (obj future))))

;; kinda silly
(define (future-get future . opt)
   (define (finish r)
      ;; now we can change the state shared.
      (future-state-set! future 'done)
      (if (eqv? (future-canceller future) #t) ;; kinda silly
	  (raise r)
	  r))
   (when (eq? (future-state future) 'terminated)
      (raise-future-terminated future))
   (let ((state (future-state future)))
      (let ((r (future-result future)))
         (finish 
            (cond ((and (not (eq? state 'done)) (shared-box? r))
                   (future-result-set! future (apply shared-box-get! r opt))
                   (future-result future))
                  ((and (not (eq? state 'done)) (procedure? r))
                   (future-result-set! future (apply r future opt))
                   (future-result future))
                  (else r))))))
;; kinda dummy
(define (future-cancel future)
   (unless (eq? (future-state future) 'done)
      (future-state-set! future 'terminated))
   (let ((c (future-canceller future)))
      (when (procedure? c)
         (c future)
         (future-canceller-set! future #f))
      #t))

(define (future-done? future) (eq? (future-state future) 'done))

(define (future-cancelled? future)
   (eq? (future-state future) 'terminated))

