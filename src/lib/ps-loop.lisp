(in-package :parenscript)

(defun complex-js-expr? (expr)
  (if (symbolp expr)
      (or (find #\. (symbol-name expr))
          (not (eq (ps-macroexpand expr) expr)))
      (consp expr)))

(defvar *loop-keywords*
  '(:for :do :when :unless :initially :finally :while :until
    :from :to :below :downto :above :by :in :across :on := :then :sum :collect
    :count :minimize :maximize :into :repeat))

(defun normalize-loop-keywords (args)
  (mapcar
   (lambda (x)
     (or (find-if (lambda (key) (and (symbolp x) (equal (symbol-name x) (symbol-name key))))
                  *loop-keywords*)
         x))
   args))

(defun reduce-function-symbol (sym)
  (if (and (consp sym) (eq 'function (first sym)))
      (second sym)
      sym))

(defun err (expected got)
  (error "PS-LOOP expected ~a, got ~a." expected got))

(defclass loop-state ()
  ((tokens :initarg :tokens :accessor tokens)
   (iterations :initform nil :accessor iterations)
   (prologue :initform nil :accessor prologue)
   (initially :initform nil :accessor initially)
   (finally :initform nil :accessor finally)
   (default-accum-var :initform nil :accessor default-accum-var)
   (default-accum-kind :initform nil :accessor default-accum-kind)
   (body :initform nil :accessor body)))

(defun nreverse-loop-state (state)
  (macrolet ((rev% (&rest accs)
               (cons 'progn (loop :for a :in accs :collect `(setf (,a state) (nreverse (,a state)))))))
    (rev% iterations prologue initially finally body))
  state)

(defun push-tokens (state toks)
  (setf (tokens state) (append toks (tokens state))))

(defun peek (state)
  (car (tokens state)))

(defun eat (state &optional what tag)
  (case what
    (:if (when (eq (peek state) tag)
           (eat state)
           (eat state)))
    (:progn (cons 'progn (loop :collect (if (consp (peek state))
                                            (eat state)
                                            (err "a compound form" (peek state)))
                           :until (atom (peek state)))))
    (otherwise (let ((tok (pop (tokens state))))
                 (when (and (eq what :atom) (not (atom tok)))
                   (err "an atom" tok))
                 tok))))

(defun prevar (var expr state)
  (pushnew (list 'var var expr) (prologue state) :key #'second)
  var)

(defmacro with-local-var ((name expr state) &body body)
  (once-only (expr)
    `(let ((,name (aif (and (complex-js-expr? ,expr) (ps-gensym))
                       (prevar it ,expr ,state)
                       ,expr)))
       ,@body)))

(defun for-from (var state)
  (let ((start (eat state))
        (op '+)
        (test-op nil)
        (by nil)
        (end nil))
    (loop while (member (peek state) '(:to :below :downto :above :by)) do
          (let ((term (eat state)))
            (if (eq term :by)
                (setf by (eat state))
                (setf op (case term ((:downto :above) '-) (otherwise '+))
                      test-op (case term (:to '>) (:below '>=) (:downto '<) (:above '<=))
                      end (eat state)))))
    (let ((test (when test-op
                  (with-local-var (v end state)
                    (list test-op var v)))))
      (push `(,var nil ,start (,op ,var ,(or by 1)) ,test :from) (iterations state)))))

(defun for-= (var bindings state)
  (let ((start (eat state))
        (then (eat state :if :then)))
    (push (list var bindings start (or then start) nil :=) (iterations state))))

(defun for-in (var bindings state)
  (with-local-var (arr (eat state) state)
    (let ((index (ps-gensym)))
      (push-tokens state `(,index :from 0 :below (length ,arr)
                                  ,var := (aref ,arr ,index)))
      (for-clause state)
      (for-clause state)
      ;; set bindings associated with original clause, e.g. "loop :for (a b) :in c"
      (setf (second (car (iterations state))) bindings))))

(defun for-on (var bindings state)
  (with-local-var (arr (eat state) state)
    (let ((by (aif (eat state :if :by)
                   `(,(reduce-function-symbol it) ,var)
                   `((@ ,var :slice) 1))))
      (push-tokens state `(,var := ,arr :then ,by))
      (for-clause state)
      (let ((this-iteration (car (iterations state))))
        (setf (second this-iteration) bindings)
        ;; set the end-test
        (setf (fifth this-iteration) `(or (null ,var) (= (length ,var) 0)))))))

(defun for-clause (state)
  (let* ((place (eat state))
         (var (when (atom place) place))
         (bindings (unless var place))
         (term (eat state :atom)))
    (when bindings
      (when (eq term :from)
        (err "an atom after FROM" bindings))
      (setf var (ps-gensym)))
    (case term
      (:from (for-from var state))
      (:= (for-= var bindings state))
      ((:in :across) (for-in var bindings state))
      (:on (for-on var bindings state))
      (otherwise (error "FOR ~s ~s is not valid in PS-LOOP." var term)))))

(defun accumulate (kind term var state)
  (when (null var)
    (when (and (default-accum-kind state) (not (eq kind (default-accum-kind state))))
      (error "PS-LOOP encountered illegal ~a: ~a was already declared, and there can only be one kind of default accumulation per loop." kind (default-accum-kind state)))
    (unless (default-accum-var state)
      (setf (default-accum-var state)
            (ps-gensym (case kind
                         (:minimize 'min)
                         (:maximize 'max)
                         (t kind))))
      (setf (default-accum-kind state) kind))
    (setf var (default-accum-var state)))
  (let ((initial (case kind
                   ((:sum :count) 0)
                   ((:maximize :minimize) nil)
                   (:collect '(array)))))
    (prevar var initial state))
  (case kind
    (:sum `(incf ,var ,term))
    (:count `(unless (null ,term) (incf ,var)))
    (:minimize `(setf ,var (if (null ,var) ,term (min ,var ,term))))
    (:maximize `(setf ,var (if (null ,var) ,term (max ,var ,term))))
    (:collect `((@ ,var :push) ,term))))

(defun repeat-clause (state)
  (let ((index (ps-gensym)))
    (setf (tokens state) (append `(,index :from 0 :below ,(eat state)) (tokens state)))
    (for-clause state)))

(defun body-clause (term state)
  (case term
    ((:when :unless) (list (intern (symbol-name term))
                           (eat state)
                           (body-clause (eat state :atom) state)))
    ((:sum :collect :count :minimize :maximize) (accumulate term (eat state) (eat state :if :into) state))
    (:do (eat state :progn))
    (otherwise (err "a PS-LOOP keyword" term))))

(defun clause (state)
  (let ((term (eat state :atom)))
    (case term
      (:for (for-clause state))
      (:repeat (repeat-clause state))
      (:while (push `(unless ,(eat state) break) (body state)))
      (:until (push `(when ,(eat state) break) (body state)))
      (:initially (push (eat state :progn) (initially state)))
      (:finally (push (eat state :progn) (finally state)))
      (otherwise (push (body-clause term state) (body state))))))

(defun parse-ps-loop (terms)
  (if (null terms)
      (err "loop definition" nil)
      (let ((state (make-instance 'loop-state :tokens terms)))
        (loop :while (tokens state) :do (clause state))
        (nreverse-loop-state state))))

(defun wrap-with-destructurings (iterations forms)
  (if (null iterations)
      forms
      (wrap-with-destructurings
       (cdr iterations)
       (aif (second (car iterations))
            `((destructuring-bind ,it ,(first (car iterations)) ,@forms))
            forms))))

(defun parallel-form (loop)
  ;; When there are parallel clauses, we want the loop to break as
  ;; soon as any clause fails its initial test (the way CL does it).
  ;; Javascript FOR loops won't give us this, because they evaluate
  ;; every clause's init form up front and only then check the test
  ;; forms. But we can get the desired behavior from a WHILE loop.
  (let ((form `(while t
                 ,@(append (body loop)
                           (loop :for (var bindings nil step test) :in (iterations loop)
                             :collect `(setf ,var ,step)
                             :when bindings :collect `(dset ,bindings ,var)
                             :when test :collect `(when ,test (break)))))))
    ;; In addition, when :INITIALLY or :FINALLY are present, we need
    ;; to lift declarations of iteration variables to prologue level,
    ;; because these clauses must be evaluated regardless of whether
    ;; or not we make it to the loop body.
    (let ((lift? (or (initially loop) (finally loop))))
      (when lift?
        (loop :for iteration :in (reverse (iterations loop))
          :for (var bindings init nil nil tag) = iteration :do
          (mapcar (lambda (b) (prevar b nil loop)) (reverse bindings))
          (if (eq tag :from)
              (progn
                (prevar var init loop)
                (setf (third iteration) nil))
              (prevar var nil loop))))
      (loop :for (var bindings init nil test) :in (reverse (iterations loop)) :do
        (when test
          (setf form `(unless ,test ,form)))
        (when bindings
          (setf form `(,(if lift? 'dset 'destructuring-bind) ,bindings ,var ,form)))
        (when init
          (setf form `(progn (,(if lift? 'setf 'var) ,var ,init)
                             ,form)))))
    form))

(defun straightforward-form (loop)
  ;; An optimization for when we can get away with a nice tight FOR loop.
  (unless (or (> (length (iterations loop)) 1)
              (initially loop)
              (finally loop))
    (flet ((inits% ()
             (mapcar (lambda (x) (list (first x) (third x)))
                     (iterations loop)))
           (steps% ()
             (mapcar (lambda (x) `(setf ,(first x) ,(fourth x)))
                     (iterations loop)))
           (test% ()
             (aif (loop :for x :in (iterations loop)
                    :when (fifth x) :collect (fifth x))
                  (if (cdr it)
                      (list 'not (cons 'or it))
                      (cons 'not it))
                  t)))
      `(for ,(inits%) (,(test%)) ,(steps%)
            ,@(wrap-with-destructurings (iterations loop) (body loop))))))

(defpsmacro loop (&rest args)
  (let* ((loop (parse-ps-loop (normalize-loop-keywords args)))
         (main (or (straightforward-form loop)
                   (parallel-form loop))))
    `(,@(if (default-accum-var loop) '(with-lambda ()) '(progn))
        ,@(prologue loop)
        ,@(initially loop)
        ,main
        ,@(finally loop)
        ,@(when (default-accum-var loop) `((return ,(default-accum-var loop)))))))
