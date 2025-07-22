(define-syntax guard
   (syntax-rules ()
      ((guard (var clause1 ...) body ...)
       (with-handler (lambda (var)
                        (let ((res (cond clause1 ...)))
                           (if res res (raise var))))
                     body ...))))