;;; -*- mode: bee; coding: utf-8 -*-
;;;
;;; util/concurrent/shared-queue.scm - Shared queue
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

;; reference
;;  http://parlab.eecs.berkeley.edu/wiki/_media/patterns/sharedqueue.pdf
;; based on SharedQueue4

(module bigloo-concurrent/shared-queue
   (library pthread)
   (export
      (final-class <shared-queue>
         (head::pair-nil (default '()))
         (tail::pair-nil (default '()))
         ;; actually we just need do (length head) but takes O(n)
         ;; better to have O(1).
         (size::long (default 0))
         ;; should a shared queue be expandable? 
         (max-length::long read-only (default -1))
         (w::long (default 0))
         ;; synchronisation stuff
         (lock::mutex read-only (default (make-mutex)))
         (read-cv::condvar read-only (default (make-condition-variable)))
         (write-cv::condvar read-only (default (make-condition-variable))))
      (make-shared-queue #!optional (max-length -1))
      (inline shared-queue? v)
      (shared-queue-empty? sq::<shared-queue>)
      (shared-queue-get! sq::<shared-queue> . maybe-timeout)
      (shared-queue-put! sq::<shared-queue> obj . maybe-timeout)
      (shared-queue-overflows? sq::<shared-queue> count)
      (shared-queue-remove! sq::<shared-queue> o . maybe=)
      (shared-queue-clear! sq::<shared-queue>)
      (shared-queue-locked? sq::<shared-queue> . maybe-wait?)
      (shared-queue-lock! sq::<shared-queue>)
      (shared-queue-unlock! sq::<shared-queue>)
      ;; shared-priority-queue
      ;; even thought the name is queue but it's not a
      ;; sub class of shared-queue.
      (final-class <shared-priority-queue>
         elements::vector
         (size::long (default 0))
         (max-length::long read-only (default -1))
         ;; procedure return -1, 0 and 1
         (compare::procedure read-only)
         ;; synchronisation stuff
         (w::long (default 0))
         (lock::mutex read-only (default (make-mutex)))
         (cv::condvar read-only (default (make-condition-variable)))
         (write-cv::condvar read-only (default (make-condition-variable))))
      
      (make-shared-priority-queue compare::procedure #!optional (max-length -1))
      (inline shared-priority-queue? v)
      (shared-priority-queue-empty? spq::<shared-priority-queue>)
      (shared-priority-queue-put! spq::<shared-priority-queue> o . maybe-timeout)
      (shared-priority-queue-get! spq::<shared-priority-queue> . maybe-timeout)
      (shared-priority-queue-remove! spq::<shared-priority-queue> o)
      (shared-priority-queue-overflows? spq::<shared-priority-queue> count)
      (shared-priority-queue-clear! spq::<shared-priority-queue>)
      (shared-priority-queue-locked? sq::<shared-priority-queue> . maybe-wait?)
      (shared-priority-queue-lock! sq::<shared-priority-queue>)
      (shared-priority-queue-unlock! sq::<shared-priority-queue>)
      (inline shared-queue-size q::<shared-queue>)
      (shared-queue-find sq::<shared-queue> proc)
      (inline shared-queue-max-length q::<shared-queue>)
      (inline shared-priority-queue-max-length pq::<shared-priority-queue>)))

;;; utility methods
(define-inline (thread? v)
   (isa? v thread))

(define div quotient)

(define-syntax let-values
   (syntax-rules ()
      ((let-values (((id ...) expr))
          body ...)
       (receive (id ...) expr
                body ...))))

(define (make-shared-queue #!optional (max-length -1))
   (instantiate::<shared-queue> (max-length max-length)))

(define-inline (shared-queue? v)
   (isa? v <shared-queue>))

;;;; shared-queue accessors to match original record type
(define-inline (shared-queue-head q::<shared-queue>)
   (-> q head))

(define-inline (shared-queue-head-set! q::<shared-queue> v::pair-nil)
   (set! (-> q head) v))

(define-inline (shared-queue-tail q::<shared-queue>)
   (-> q tail))

(define-inline (shared-queue-tail-set! q::<shared-queue> v::pair-nil)
   (set! (-> q tail) v))

(define-inline (shared-queue-size q::<shared-queue>)
   (-> q size))

(define-inline (shared-queue-size-set! q::<shared-queue> v::long)
   (set! (-> q size) v))

(define-inline (shared-queue-max-length q::<shared-queue>)
   (-> q max-length))

(define-inline (%w  q::<shared-queue>)
   (-> q w))

(define-inline (%w-set! q::<shared-queue> v::long)
   (set! (-> q w) v))

(define-inline (%lock q::<shared-queue>)
   (-> q lock))

(define-inline (%read-cv q::<shared-queue>)
   (-> q read-cv))

(define-inline (%write-cv q::<shared-queue>)
   (-> q write-cv))
;;;; end shared-queue accesors

(define (shared-queue-empty? sq)
   (null? (shared-queue-head sq)))


(define (shared-queue-get! sq . maybe-timeout)
   (let ((timeout (if (pair? maybe-timeout) (car maybe-timeout) 0))
         (timeout-value (if (and (pair? maybe-timeout)
                                 (pair? (cdr maybe-timeout)))
                            (cadr maybe-timeout)
                            #f)))
      (synchronize (%lock sq)
         (%w-set! sq (+ (%w sq) 1))
         (condition-variable-broadcast! (%write-cv sq))
         (let loop ()
            (cond ((shared-queue-empty? sq)
                   (cond ((condition-variable-wait! (%read-cv sq) (%lock sq) timeout)
                          (loop))
                         (else
                          ;; do we need to reduce this?
                          (%w-set! sq (- (%w sq) 1))
                          timeout-value)))
               (else
                (%w-set! sq (- (%w sq) 1))
                (let ((head (shared-queue-head sq)))
                   (shared-queue-head-set! sq (cdr head))
                   (when (null? (cdr head))
                      (shared-queue-tail-set! sq '()))
                   (shared-queue-size-set! sq (- (shared-queue-size sq) 1))
                   (car head))))))))

(define (shared-queue-put! sq obj . maybe-timeout)
   (let ((timeout (if (pair? maybe-timeout) (car maybe-timeout) 0))
         (timeout-value (if (and (pair? maybe-timeout)
                                 (pair? (cdr maybe-timeout)))
                            (cadr maybe-timeout)
                            #f)))
      (synchronize (%lock sq)
         (let loop ()
            (cond ((if (zero? (shared-queue-max-length sq))
                       (zero? (%w sq))
                       (shared-queue-overflows? sq 1))
                   (cond ((condition-variable-wait! (%write-cv sq) (%lock sq) timeout)
                          (loop))
                         (else
                          timeout-value)))
                  (else
                   (let ((new (list obj))
                         (tail (shared-queue-tail sq)))
                      (shared-queue-tail-set! sq new)
                      (if (pair? tail)
                          (set-cdr! tail new)
                          (shared-queue-head-set! sq new))
                      (shared-queue-size-set! sq (+ (shared-queue-size sq) 1))
                      (when (> (%w sq) 0)
                         (condition-variable-broadcast! (%read-cv sq)))
                      obj)))))))

(define (shared-queue-overflows? sq count)
   (and (>= (shared-queue-max-length sq) 0)
        (> (+ count (shared-queue-size sq)) (shared-queue-max-length sq))))

(define (shared-queue-remove! sq o . maybe=)
   (define = (if (null? maybe=) equal? (car maybe=)))
   (define (find-it prev cur)
      (cond ((null? cur) #f)
	    ;; this works because cdr of cur won't be '()
	    ;; (last element is already checked)
	    ((= (car cur) o) (set-cdr! prev (cdr cur)) #t)
	    (else (find-it (cdr prev) (cdr cur)))))
   (define (remove-it sq)
      (let ((h (shared-queue-head sq))
	    (t (shared-queue-tail sq)))
         (cond ((null? h) #f) ;; ok not there
               ((= (car h) o)
                (let ((n (cdr h)))
                   (shared-queue-head-set! sq n)
                   (when (null? n) (shared-queue-tail-set! sq '()))
                   #t))
               ((= (car t) o)
                (let loop ((h h))
                   (cond ((eq? (cdr h) t)
                          (set-cdr! h '())
                          (shared-queue-tail-set! sq h) #t)
                         (else (loop (cdr h))))))
               (else (find-it h (cdr h))))))
   
   (synchronize (%lock sq)
      (let ((r (remove-it sq)))
      (when r (shared-queue-size-set! sq (- (shared-queue-size sq) 1)))
      r)))

(define (shared-queue-clear! sq)
   (synchronize (%lock sq)
      (shared-queue-size-set! sq 0)
      (shared-queue-head-set! sq '())
      (shared-queue-tail-set! sq '())))

(define (shared-queue-find sq proc)
   (synchronize (%lock sq)
      (find proc (shared-queue-head sq))))

;; this is rather stupid process but needed.
;; scenario: 
;;  A thread (A) which tries to put an object into shared-queue. Then other
;;  thread (B) tries to terminate the thread (A) with thread-terminate! and
;;  the lock is still held by (A). Then (B) re-uses the shared-queue with
;;  abondaned mutex. To avoid the case, we need to have this procedure to
;;  check if the queue is currently locked or not.
;; I know this is a very very very x 1000 bad scenario.
(define (shared-queue-locked? sq . maybe-wait?)
   (let ((wait? (if (null? maybe-wait?) #f (car maybe-wait?))))
      (and (mutex-locked? (%lock sq))
           (if wait?
               ;; it's locked so wait if requires
               (synchronize (%lock sq) #f)
               #t))))

(define (shared-queue-lock! sq) (mutex-lock! (%lock sq)))
(define (shared-queue-unlock! sq) (mutex-unlock! (%lock sq)))

;; priority queue
;; we do simply B-tree

(define (make-shared-priority-queue compare::procedure #!optional (max-length -1))
   (let ((capacity (if (> max-length 0) max-length 10)))
      (instantiate::<shared-priority-queue>
         (elements (make-vector capacity))
         (compare compare)
         (max-length max-length))))

(define-inline (shared-priority-queue? v)
   (isa? v <shared-priority-queue>))

;;;; priority queue accessors to match original record type

(define-inline (%spq-es pq::<shared-priority-queue>)
   (-> pq elements))

(define-inline (%spq-es-set! pq::<shared-priority-queue> v)
   (set! (-> pq elements) v))

(define-inline (shared-priority-queue-size pq::<shared-priority-queue>)
   (-> pq size))

(define-inline (%spq-size-set! pq::<shared-priority-queue> s)
   (set! (-> pq size) s))

(define-inline (shared-priority-queue-max-length pq::<shared-priority-queue>)
   (-> pq max-length))

(define-inline (shared-priority-queue-compare pq::<shared-priority-queue>)
   (-> pq compare))

(define-inline (%spq-w pq::<shared-priority-queue>)
   (-> pq w))

(define-inline (%spq-w-set! pq::<shared-priority-queue> v::long)
   (set! (-> pq w) v))

(define-inline (%spq-lock pq::<shared-priority-queue>)
   (-> pq lock))

(define-inline (%spq-cv pq::<shared-priority-queue>)
   (-> pq cv))

(define-inline (%spq-wcv pq::<shared-priority-queue>)
   (-> pq write-cv))

;;;; end priority queue accessors 

(define (shared-priority-queue-empty? spq) 
   (zero? (shared-priority-queue-size spq)))

(define (shared-priority-queue-put! spq o . maybe-timeout)
   (define size (shared-priority-queue-size spq))
   (define (grow! spq min-capacity)
      (define old (%spq-es spq))
      ;; double if it's small, otherwise 50%.
      (let* ((capacity (+ size (if (< size 64)
                                   (+ size 2)
                                   (div size 2))))
	     (new (make-vector capacity)))
         (do ((i 0 (+ i 1)))
             ((= i size))
             (vector-set! new i (vector-ref old i)))
         (%spq-es-set! spq new)))
   ;; timeout
   (define timeout (if (pair? maybe-timeout) (car maybe-timeout) 0))
   (define timeout-value (if (and (pair? maybe-timeout)
                                  (pair? (cdr maybe-timeout)))
                             (cadr maybe-timeout)
                             #f))
   
   (synchronize (%spq-lock spq)
      (let loop ()
      (cond ((if (zero? (shared-priority-queue-max-length spq))
		 (zero? (%spq-w spq))
		 (shared-priority-queue-overflows? spq 1))
	     (cond ((condition-variable-wait! (%spq-wcv spq) (%spq-lock spq) timeout)
		    (loop))
		   (else
                    timeout-value)))
	    (else
	     (when (>= size (vector-length (%spq-es spq)))
                (grow! spq (+ size 1)))
	     (if (zero? size)
		 (vector-set! (%spq-es spq) 0 o)
		 (shift-up spq size o))
	     (%spq-size-set! spq (+ size 1))
	     (when (> (%spq-w spq) 0)
                (condition-variable-broadcast! (%spq-cv spq)))
	     o))))
   )

(define (shared-priority-queue-get! spq . maybe-timeout)
   (let ((timeout (if (pair? maybe-timeout) (car maybe-timeout) 0))
         (timeout-value (if (and (pair? maybe-timeout)
                                 (pair? (cdr maybe-timeout)))
                            (cadr maybe-timeout)
                            #f)))
      (synchronize (%spq-lock spq)
         (%spq-w-set! spq (+ (%spq-w spq) 1))
         (condition-variable-broadcast! (%spq-wcv spq))
         (let loop ()
            (cond ((shared-priority-queue-empty? spq)
                   (cond ((condition-variable-wait! (%spq-cv spq) (%spq-lock spq) timeout)
                          (loop))
                         (else
                          (%spq-w-set! spq (- (%spq-w spq) 1))
                          timeout-value)))
               (else
                (%spq-w-set! spq (- (%spq-w spq) 1))
                (%spq-size-set! spq (- (shared-priority-queue-size spq) 1))
                (let* ((s (shared-priority-queue-size spq))
                       (es (%spq-es spq))
                       (r (vector-ref es 0))
                       (x (vector-ref es s)))
                   (vector-set! es s #f)
                   (unless (zero? s) (shift-down spq 0 x))
                   r)))))))

(define (shared-priority-queue-remove! spq o)
   (define cmp (shared-priority-queue-compare spq))
   (define es (%spq-es spq))
   (define (find)
      (define len (shared-priority-queue-size spq))
      (let loop ((i 0))
         (cond ((= i len) -1)
               ((zero? (cmp o (vector-ref es i))) i)
               (else (loop (+ i 1))))))
   ;;; (%spq-lock spq) must be locked when calling remove-at
   (define (remove-at spq index)
      (%spq-size-set! spq (- (shared-priority-queue-size spq) 1))
      (let ((s (shared-priority-queue-size spq)))
         (if (= s index)
             (vector-set! es s #f)
             (let ((moved (vector-ref es s)))
                (vector-set! es s #f)
                (shift-down spq index moved)
                (when (eq? (vector-ref es index) moved)
                   (shift-up spq index moved))))))
   (synchronize (%spq-lock spq)
      (let ((index (find)))
         (if (>= index 0)
	  (begin (remove-at spq index) #t)
	  #f)))
   )

(define (shift-up spq index o)
   (define cmp (shared-priority-queue-compare spq))
   (define es (%spq-es spq))
   (let loop ((k index))
      (if (> k 0)
	  (let* ((parent (div (- k 1) 2))
		 (e (vector-ref es parent)))
             (if (>= (cmp o e) 0)
                 (vector-set! es k o)
                 (begin
                    (vector-set! es k e)
                    (loop parent))))
	  (vector-set! es k o))))

(define (shift-down spq k x)
   (define cmp (shared-priority-queue-compare spq))
   (define es (%spq-es spq))
   (define size (shared-priority-queue-size spq))
   (define half (div size 2))
   (let loop ((k k))
      (if (< k half)
	  (let* ((child (+ (* k 2) 1))
		 (o (vector-ref es child))
		 (right (+ child 1)))
             (let-values (((o child)
                           (if (and (< right size)
                                    (> (cmp o (vector-ref es right)) 0))
                               (values (vector-ref es right) right)
                               (values o child))))
                (if (<= (cmp x o) 0)
                    (vector-set! es k x)
                    (begin
                       (vector-set! es k o)
                       (loop child)))))
	  (vector-set! es k x))))

(define (shared-priority-queue-overflows? spq count)
   (and (>= (shared-priority-queue-max-length spq) 0)
        (> (+ count (shared-priority-queue-size spq)) 
           (shared-priority-queue-max-length spq))))

(define (shared-priority-queue-clear! spq) 
   (synchronize (%spq-lock spq)
      ;; clear it
      (do ((len (shared-priority-queue-size spq))
           (es (%spq-es spq))
           (i 0 (+ i 1)))
          ((= i len) 
           (%spq-size-set! spq 0))
          (vector-set! es i #f))))

(define (shared-priority-queue-locked? sq . maybe-wait?)
   (let ((wait? (if (null? maybe-wait?) #f (car maybe-wait?))))
      (and (mutex-locked? (%spq-lock sq))
	   ;; it's locked so wait if requires
	   (if wait?
	       (synchronize (%spq-lock sq)
                  #f)
	       #t))))

(define (shared-priority-queue-lock! sq) (mutex-lock! (%spq-lock sq)))
(define (shared-priority-queue-unlock! sq) (mutex-unlock! (%spq-lock sq)))

;; mutex-state has different behavior in the pthread and java
;; backends for the bigloo threads library. The pthread backend
;; returns 'locked or 'unlocked from mutex-state whereas the java
;; backend returns either the thread when locked or 'not-abandoned
;; when not locked or 'abandoned if it has been abandoned by its owning thread
(define-inline (mutex-locked? m)
   (let ((state (mutex-state m)))
      (or (eq? 'locked state)
          (not (symbol? state)))))

;; Local Variables:
;; coding: utf-8-unix
;; End:
