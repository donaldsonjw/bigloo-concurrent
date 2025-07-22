(module bigloo-concurrent/make_lib
   (import bigloo-concurrent/shared-queue
           bigloo-concurrent/thread-pool
           bigloo-concurrent/future
           bigloo-concurrent/executor)
   (eval (export-all)))
