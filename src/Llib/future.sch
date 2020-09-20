;; for convenience default using simple future
(define-syntax future
    (syntax-rules (class)
       ((_ (class cls) expr ...)
        ((class-creator cls)
         (lambda () expr ...)
         (make-shared-box)
         'created
         #f
         (make-mutex)))
       ((_ expr ...)
        (make-simple-future (lambda () expr ...)))))