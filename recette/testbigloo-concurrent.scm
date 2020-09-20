(module testbigloo-concurrent
   (library btest bigloo-concurrent pthread srfi117)
   (main main))

(define-syntax dotimes
   (syntax-rules ()
      ((dotime (ivar limit) exp ...)
       (let loop ((ivar 0))
          (if (= ivar limit)
              #t
              (begin
                 exp ... (loop (+ ivar 1))))))))


(define-test-suite bigloo-concurrent-tests   
   (test "shared-queue"
      (let ()
         (define (open-account initial-amount out)
            (define shared-queue (make-shared-queue))
            (define (process)
               (define balance initial-amount)
               (let loop ()
                  (let ((command (shared-queue-get! shared-queue)))
                     (case (car command)
                        ((withdrow)
                         (let ((how-much (cadr command)))
                            (if (< balance how-much)
                                (begin (shared-queue-put! out "invalid amount") (loop))
                                (begin
                                   (set! balance (- balance how-much))
                                 (shared-queue-put! out (cons how-much balance))
                                 (loop)))))
                        ((deposite)
                         (let ((a (cadr command)))
                            (if (negative? a)
                                (begin (shared-queue-put! out "invalid amount") (loop))
                                (begin
                                   (set! balance (+ balance a))
                                   (shared-queue-put! out (cons 0 balance))
                                   (loop)))))
                        ((close) #t)
                        (else "invalid message"0)))))
            
            (let ((t (make-thread process)))
               (thread-start-joinable! t)
               shared-queue)) 
         
         (define recepit (make-shared-queue))
         (define client (open-account 1000 recepit))
         (define eager-client
            (thread-start-joinable!
               (make-thread
                  (lambda ()
                     (assert-equal? '(100 . 900)
                        (shared-queue-get! recepit))))))
         
         (shared-queue-put! client '(withdrow 100))
         (shared-queue-put! client '(deposite 100))
         (shared-queue-put! client '(close))
         ;; wait until eager client is done
         (thread-join! eager-client)
         
       (assert-equal?  1 (shared-queue-size recepit))
       (assert-equal? '(0 . 1000) (shared-queue-get! recepit))
       (assert-true (shared-queue-empty? recepit))))

   (test "max-length test"
      (let ()
         (define shared-queue (make-shared-queue 1))
         (assert-equal? 1 (shared-queue-max-length shared-queue))
         
         (assert-equal? 1 (shared-queue-put! shared-queue 1))
         (assert-equal?  'boom 
            (shared-queue-put! shared-queue 1 1 'boom))
         (assert-true (shared-queue-overflows? shared-queue 1))))

   (test "max-length 0"
      (let ()
         (define shared-queue (make-shared-queue 0))
         (define results '())
         (define reader
            (make-thread
               (lambda ()
                  (set! results (cons 'r results))
                  (shared-queue-get! shared-queue))))
         
         (define writer
            (thread-start-joinable!
               (make-thread
                  (lambda ()
                     (shared-queue-put! shared-queue 'wakeup)
                     (set! results (cons 'w results))
                     'awake))))
         (assert-equal? 0 (shared-queue-max-length shared-queue))
         (assert-true  (shared-queue-overflows? shared-queue 1))
         ;; queue doesn't have reader
         (assert-equal? 
             #f (shared-queue-put! shared-queue 1 1 #f))
         (thread-start-joinable! reader)
         (assert-equal? 'wakeup (thread-join! reader))
         (assert-equal? 'awake (thread-join! writer))
         (assert-equal? '(w r) results)
         ))

   (test "lock / unlock"
      (let ((sq (make-shared-queue 0)))
         (assert-true (shared-queue-lock! sq))
         (assert-true (shared-queue-locked? sq))
         (assert-true (shared-queue-unlock! sq))
         ))

   (test   "remove!"
      (define (test-remove! lis o)
         (define len (length lis))
         (let ((sq (make-shared-queue)))
            (for-each (lambda (o) (shared-queue-put! sq o)) lis)
            (assert-true (shared-queue-remove! sq o))
            (assert-true (not (shared-queue-remove! sq o)))
            (assert-equal?  (- len 1) (shared-queue-size sq))
            (assert-equal? (delete o lis)
               (let loop ((r '()))
                  (if (shared-queue-empty? sq)
                      (reverse r)
                      (loop (cons (shared-queue-get! sq) r)))))))
      (test-remove! '(1 2 3 4 5) 3)
      (test-remove! '(1 2 3 4 5) 1)
      (test-remove! '(1 2 3 4 5) 5))

   (test "shared-priority-queue"
      (let ((compare (lambda (a b) (cond ((= a b) 0) ((< a b) -1) (else 1)))))
         (define spq (make-shared-priority-queue compare))
         (define (push . args)
            (for-each (lambda (arg)
                         (assert-equal?  arg
        		    (shared-priority-queue-put! spq arg)))
               args))
         (define (pop . args)
            (for-each (lambda (arg)
                         (assert-equal?  arg
        		    (shared-priority-queue-get! spq)))
               args))
         (push 10 8 1 9 7 5 6)
         (pop 1 5 6 7 8 9 10)
         
         (push 9 8 10)
         (assert-true (shared-priority-queue-remove! spq 9))
         (assert-true (not (shared-priority-queue-remove! spq 9)))
         (pop 8 10)
         
         (let* ((lock (make-mutex))
                (cv (make-condition-variable))
                (ready? #f)
                (f (make-thread
                      (lambda ()
                         (mutex-lock! lock)
                         ;; wait until ready
                         (let loop  ()
                            (unless ready?
                               (condition-variable-wait! cv lock)
                               (loop))
                            (mutex-unlock! lock))
                         ;; get all
                         (let loop ((r '()))
                            (if (shared-priority-queue-empty? spq)
                                (reverse r)
                                (loop (cons (shared-priority-queue-get! spq) r))))))))
            (mutex-lock! lock)
            (thread-start-joinable! f)
            (push 5 1 7 2 8 4 6 3)
            ;; on single core environment, the thread would be executed after
            ;; the main thread process is done. so we need to do this trick,
            ;; otherwise it wait until condition-variable is signaled which
            ;; is already done by main thread...
            (set! ready? #t)
            (condition-variable-broadcast! cv)
            (mutex-unlock! lock)
            (assert-equal? '(1 2 3 4 5 6 7 8) (thread-join! f))
            ))
      
      (let ((compare (lambda (a b) (cond ((= a b) 0) ((< a b) -1) (else 1)))))
         (define spq (make-shared-priority-queue compare 1))
         (assert-equal?  1 (shared-priority-queue-max-length spq))
         
         (assert-equal?  1 
            (shared-priority-queue-put! spq 1))
         (assert-equal?  'boom 
            (shared-priority-queue-put! spq 1 1 'boom))
         (assert-true (shared-priority-queue-overflows? spq 1)))
      )

   (test "thread-pool"
      (let ((pool (make-thread-pool 5)))
         (define (crop sq)
            (let loop ((r '()))
               (if (shared-queue-empty? sq)
                   r
                   (loop (cons (shared-queue-get! sq) r)))))
         (define (custom-add-to-back n)
            (if (negative? n)
                (error 'dummy "failed to add" n)
                #f))
         (assert-true (thread-pool? pool))
         (assert-equal? 5 (thread-pool-size pool))
         (assert-equal? 5 (thread-pool-idling-count pool))
         (assert-equal? 0 (thread-pool-push-task! pool (lambda () #t)))
         (assert-true (thread-pool-wait-all! pool))
         (let ((sq (make-shared-queue)))
            (do ((i 0 (+ i 1)))
                ((= i 10)
                 (thread-pool-wait-all! pool)
                 (assert-equal? 
                    '(0 1 2 3 4 5 6 7 8 9)
                    (sort < (crop sq))))
                (thread-pool-push-task! pool
                   (lambda ()
                      (thread-sleep! 0.1)
                      (shared-queue-put! sq i)))))
         (assert-exception-thrown  
            (do ((i 0 (+ i 1)))
                ((= i 10) (thread-pool-wait-all! pool) #f)
                (thread-pool-push-task! pool
                   ;; just wait
                   (lambda () (thread-sleep! 1))
                   custom-add-to-back)) &error)
         )
      
      (let* ((pool (make-thread-pool 1 raise))
             (id (thread-pool-push-task! pool (lambda () (error 'dummy "msg" '())))))
        (assert-true (thread-pool-wait-all! pool))
        (assert-true (not (thread-pool-thread-task-running? pool id)))))

   (test "simple future"
      (let ((f1 (future (thread-sleep! .1) 'ok))
            (f2 (future (error 'dummy "dummy" '()))))
         (assert-true (simple-future? f1))
         (assert-true (simple-future? f2))
         (assert-equal?  'ok (future-get f1))
         (assert-exception-thrown (future-get f2) &error)))

   (test "thread pool executor"
      (let ((executor (make-thread-pool-executor 1)))
         (assert-true (executor? executor))
         (assert-equal? 1 (thread-pool-executor-max-pool-size executor))
         (assert-equal? 0 (thread-pool-executor-pool-size executor))
         (assert-equal? 'running (executor-state executor))))

   (test "executor future"
      (let ((future (make-executor-future (lambda () 1))))
         (assert-true (future? future))
         (assert-true (not (future-done? future)))
         (assert-true (not (future-cancelled? future)))
         (assert-exception-thrown (future-get future) &assertion)
         ))

   (test "thread pool executor 2"
      (let ((e (make-thread-pool-executor 1))
          (f1 (future (class <executor-future>) 1))
          (f2 (future (class <executor-future>) (thread-sleep! 10)))
          (f3 (future (class <executor-future>) (thread-sleep! 10))))
       (assert-true (executor? (execute-future! e f1)))
       (future-get f1)
       (assert-equal?  1 (future-get f1))
       (assert-true  (future-done? f1))
       (assert-true  (not (future-cancelled? f1)))
       (assert-true  (executor? (execute-future! e f2)))
       (assert-true  (not (executor-available? e)))
       (assert-exception-thrown (execute-future! e f3) &rejected-execution-error)
       (assert-equal? 1 (thread-pool-executor-pool-size e))
       (assert-true  (future-cancel f2))
       (assert-true  (future-cancelled? f2))
       (assert-exception-thrown (future-get f2) &future-terminated)
       (assert-equal? 0 (thread-pool-executor-pool-size e))
       ))

   (test "concurrent executor" 
     (let* ((e (make-thread-pool-executor 1))
            (t1 (make-thread (lambda ()
                                (let ((f (future (class <executor-future>) 
                                            (thread-sleep! 1000000))))
                                   (execute-future! e f)))))
            (t2 (make-thread (lambda ()
                               (let ((f (future (class <executor-future>)
                                           (thread-sleep! 1000000))))
                                  (execute-future! e f))))))  
        ;; hope we get there
        (map thread-start-joinable! (list t1 t2))
        (sleep 500000)
        (assert-equal?  1 (thread-pool-executor-pool-size e))
        
        (assert-true (with-handler (lambda (e)
                                      (if (and (isa? e uncaught-exception)
                                               (with-access::uncaught-exception e (reason)
                                                  (isa? reason &rejected-execution-error)))
                                          #t
                                          (raise e)))
                                   ;; one of them must be failed
                                   (begin (thread-join! t1) (thread-join! t2))))))

    (test "executor-submit!"
       (let ((e (make-thread-pool-executor 1 push-future-handler))
             (f* '()))
          (assert-true (let ((f (executor-submit! e (lambda () 1))))
                          (set! f* (cons f f*))
                          (future? f)))
          (assert-true (let ((f (executor-submit! e (lambda () 2))))
                          (set! f* (cons f f*))
                          (future? f)))
          (assert-true (let ((f (executor-submit! e (lambda () 3))))
                          (set! f* (cons f f*))
                          (future? f)))
          (assert-equal? '(3 2 1) (map future-get f*))))

    (test "fork-join-executor"
       (let ((e (make-fork-join-executor))
             (f* '()))
          (assert-true (let ((f (executor-submit! e (lambda () 1))))
                          (set! f* (cons f f*))
                          (future? f)))
          (assert-true (let ((f (executor-submit! e (lambda () 2))))
                          (set! f* (cons f f*))
                          (future? f)))
          (assert-true (let ((f (executor-submit! e (lambda () 3))))
                          (set! f* (cons f f*))
                          (future? f)))
          (map future-get f*)
          (assert-equal? '(3 2 1) (map future-get f*))))

   (test  "shutdown"
      (let ((e (make-thread-pool-executor 3))
            (f1 (future (class <executor-future>) (thread-sleep! 10000)))
            (f2 (future (class <executor-future>) (thread-sleep! 10000)))
            (f3 (future (class <executor-future>) (thread-sleep! 10000))))
         (assert-true (executor? (execute-future! e f1)))
         (assert-true (executor? (execute-future! e f2)))
         (assert-true (executor? (execute-future! e f3)))
         (assert-equal? 'timeout (future-get f1 1 'timeout))
         (assert-equal? 3 (thread-pool-executor-pool-size e))
         (assert-true  (shutdown-executor! e))
         (assert-equal?  0 (thread-pool-executor-pool-size e))
         (assert-true (future-cancelled? f1))
         (assert-true (future-cancelled? f2))
         (assert-true (future-cancelled? f3))
         )

    (let ((e (make-thread-pool-executor 1 terminate-oldest-handler))
          (f1 (future (class <executor-future>) (thread-sleep! 10000)))
          (f2 (future (class <executor-future>) (thread-sleep! 10000)))
          (f3 (future (class <executor-future>) (thread-sleep! 10000))))
       (assert-true (executor? (execute-future! e f1)))
       (assert-true (executor? (execute-future! e f2)))
       (assert-true  (future-cancelled? f1))
       (assert-true  (executor? (execute-future! e f3)))
       (assert-true  (future-cancelled? f2))
       (assert-equal?  1 (thread-pool-executor-pool-size e))
       (assert-true (shutdown-executor! e))
       (assert-equal? 0 (thread-pool-executor-pool-size e))
       (assert-true (future-cancelled? f3)))

    (let ((e (make-thread-pool-executor 1 terminate-oldest-handler)))
       (assert-true
          (dotimes (i 100)
             (let ((f1 (future (class <executor-future>) 
                          (thread-sleep! 10000)))
                   (f2 (future (class <executor-future>) 
                          (thread-sleep! 10000)))
                   (f3 (future (class <executor-future>) 
                          (thread-sleep! 10000))))
                (execute-future! e f1)
                (execute-future! e f2)
                (execute-future! e f3))))
       (assert-true (shutdown-executor! e)))

    (let* ((e (make-thread-pool-executor 1 push-future-handler))
           (sq1 (make-shared-queue))
           (sq2 (make-shared-queue))
           (f1 (future (class <executor-future>) (shared-queue-get! sq1)))
           (f2 (future (class <executor-future>) (shared-queue-get! sq2))))
       (assert-true  (executor? (execute-future! e f1)))
       (assert-true  (executor? (execute-future! e f2)))
       (assert-true  (not (executor-available? e)))
       ;; weird, huh?
       (assert-equal?  2 (thread-pool-executor-pool-size e))
       ;; let it finish
       (shared-queue-put! sq1 #t)
       (shared-queue-put! sq2 #t)
       (assert-true  (shutdown-executor! e)))
     )
   
   )


(define (main args)
   (let ((tr (instantiate::terminal-test-runner (suite bigloo-concurrent-tests))))
      (if (test-runner-execute tr #t) 0 -1))
   )



