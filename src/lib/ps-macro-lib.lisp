(in-package "PARENSCRIPT")

;;; Handy utilities for doing common tasks found in many web browser
;;; JavaScript implementations

(defpsmacro do-set-timeout ((timeout) &body body)
  `(set-timeout (lambda () ,@body) ,timeout))

;;; Arithmetic

(defmacro def-js-maths (&rest mathdefs)
  `(progn ,@(mapcar (lambda (def) (cons 'defpsmacro def)) mathdefs)))

(def-js-maths
    (max (&rest nums) `((@ *math max) ,@nums))
    (min (&rest nums) `((@ *math min) ,@nums))
    (floor (n &optional divisor) `((@ *math floor) ,(if divisor `(/ ,n ,divisor) n)))
    (ceiling (n &optional divisor) `((@ *math ceil) ,(if divisor `(/ ,n ,divisor) n)))
    (round (n &optional divisor) `((@ *math round) ,(if divisor `(/ ,n ,divisor) n)))
    (sin (n) `((@ *math sin) ,n))
    (cos (n) `((@ *math cos) ,n))
    (tan (n) `((@ *math tan) ,n))
    (asin (n) `((@ *math asin) ,n))
    (acos (n) `((@ *math acos) ,n))
    (atan (y &optional x) (if x `((@ *math atan2) ,y ,x) `((@ *math atan) ,y)))
    (sinh (n) `((lambda (x) (return (/ (- (exp x) (exp (- x))) 2))) ,n))
    (cosh (n) `((lambda (x) (return (/ (+ (exp x) (exp (- x))) 2))) ,n))
    (tanh (n) `((lambda (x) (return (/ (- (exp x) (exp (- x))) (+ (exp x) (exp (- x)))))) ,n))
    (asinh (n) `((lambda (x) (return (log (+ x (sqrt (1+ (* x x))))))) ,n))
    (acosh (n) `((lambda (x) (return (* 2 (log (+ (sqrt (/ (1+ x) 2)) (sqrt (/ (1- x) 2))))))) ,n))
    (atanh (n) `((lambda (x) (return (/ (- (log (+ 1 x)) (log (- 1 x))) 2))) ,n))
    (1+ (n) `(+ ,n 1))
    (1- (n) `(- ,n 1))
    (abs (n) `((@ *math abs) ,n))
    (evenp (n) `(not (oddp ,n)))
    (oddp (n) `(% ,n 2))
    (exp (n) `((@ *math exp) ,n))
    (expt (base power) `((@ *math pow) ,base ,power))
    (log (n &optional base)
      (or (and (null base) `((@ *math log) ,n))
          (and (numberp base) (= base 10) `(* (log ,n) (@ *math *log10e*)))
          `(/ (log ,n) (log ,base))))
    (sqrt (n) `((@ *math sqrt) ,n))
    (random (&optional upto) (if upto
                                 `(floor (* ,upto ((@ *math random))))
                                 '((@ *math random)))))

(define-ps-symbol-macro pi (@ *math *pi*))

;;; Exception handling

(defpsmacro ignore-errors (&body body)
  `(try (progn ,@body) (:catch (e))))

;;; Data structures

(defpsmacro [] (&rest args)
  `(array ,@(mapcar (lambda (arg)
                      (if (and (consp arg) (not (equal '[] (car arg))))
                          (cons '[] arg)
                          arg))
                    args)))

(defpsmacro length (a)
  `(@ ,a length))

;;; Misc

(defpsmacro null (x)
  `(= ,x nil))

(defpsmacro undefined (x)
  `(=== undefined ,x))

(defpsmacro defined (x)
  `(not (undefined ,x)))

(defpsmacro @ (obj &rest props)
  "Handy slot-value/aref composition macro."
  (if props
      `(@ (slot-value ,obj ,(if (symbolp (car props)) `',(car props) (car props))) ,@(cdr props))
      obj))

(defpsmacro concatenate (result-type &rest sequences)
  (assert (equal result-type ''string) () "Right now Parenscript 'concatenate' only support strings.")
  (cons '+ sequences))

(defmacro concat-string (&rest things)
  "Like concatenate but prints all of its arguments."
  `(format nil "~@{~A~}" ,@things))

(defpsmacro concat-string (&rest things)
  (cons '+ things))

(defpsmacro elt (array index)
  `(aref ,array ,index))

(defpsmacro with-lambda (()  &body body)
  "Wraps BODY in a lambda so that it can be treated as an expression."
  `((lambda () ,@body)))

(defpsmacro stringp (x)
  `(= (typeof ,x) "string"))

(defpsmacro numberp (x)
  `(= (typeof ,x) "number"))

(defpsmacro functionp (x)
  `(= (typeof ,x) "function"))

(defpsmacro objectp (x)
  `(= (typeof ,x) "object"))

(defpsmacro memoize (fn-expr)
  (destructuring-bind (defun fn-name (arg) &rest fn-body)
      fn-expr
    (declare (ignore defun))
    (with-ps-gensyms (table value compute-fn)
      `(let ((,table {}))
         (defun ,compute-fn (,arg) ,@fn-body)
         (defun ,fn-name (,arg)
           (let ((,value (aref ,table ,arg)))
             (when (null ,value)
               (setf ,value (,compute-fn ,arg))
               (setf (aref ,table ,arg) ,value))
             (return ,value)))))))

(defpsmacro append (arr1 &rest arrs)
  (if arrs
      `((@ ,arr1 :concat) ,@arrs)
      arr1))

(defpsmacro apply (fn &rest args)
  (let ((arglist (if (> (length args) 1)
                     `(append (list ,@(butlast args)) ,(car (last args)))
                     (first args))))
    `((@ ,fn :apply) this ,arglist)))

(defpsmacro destructuring-bind (vars expr &body body)
  ;; a simple implementation that for now only supports flat lists,
  ;; but does allow NIL bindings to indicate ignore (a la LOOP)
  (let* ((arr (if (complex-js-expr? expr) (ps-gensym) expr))
         (n -1)
         (bindings
          (append (unless (equal arr expr) `((,arr ,expr)))
                  (mapcan (lambda (var)
                            (incf n)
                            (when var `((,var (aref ,arr ,n))))) vars))))
    `(let* ,bindings ,@body)))
