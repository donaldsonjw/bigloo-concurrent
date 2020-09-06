(define-syntax with-atomic
   (syntax-rules ()
      ((_ executor expr ...)
       (synchronize (executor-mutex executor)
          expr ...))))

