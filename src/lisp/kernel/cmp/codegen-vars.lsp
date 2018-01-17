;;;
;;;    File: cmpvars.lsp
;;;

;; Copyright (c) 2014, Christian E. Schafmeister
;; 
;; CLASP is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Library General Public
;; License as published by the Free Software Foundation; either
;; version 2 of the License, or (at your option) any later version.
;; 
;; See directory 'clasp/licenses' for full details.
;; 
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;; THE SOFTWARE.

;; -^-


(in-package :compiler)

#+(or)
(progn
  (defmacro cv-log (fmt &rest fmt-args)
    `(core:bformat *debug-io* ,fmt ,@fmt-args))
  (defmacro cv-log-do (&rest body)
    `(progn ,@body)))
    
;;#+(or)
(progn
  (defmacro cv-log (fmt &rest fmt-args) nil)
  (defmacro cv-log-do (&rest body)
    nil))


(defstruct (closure-cell (:type vector) :named)
  environment old-index new-index symbol)

;;; Store all lexical variable references in the following list
;;; These can be used at the end of compilation to convert
;;; variables in activation frame slots that don't need to be closed over
;;; into allocas in the current function.
#+optimize-bclasp
(progn
  (defstruct (lexical-variable-reference (:type vector))
    symbol start-env start-renv depth index instruction #+debug-lexical-depth ensure-frame-unique-id ref-env)
  (defvar *lexical-variable-references*))


;;; kind can be :make-value-frame-set-parent-from-closure or
;;;   :make-value-frame-set-parent
#+optimize-bclasp
(progn
  (defstruct (value-frame-maker-reference (:type vector))
    instruction #+debug-lexical-depth frame-unique-id #+debug-lexical-depth set-frame-unique-id new-env new-renv parent-env parent-renv)
  (defvar *make-value-frame-instructions*))

#+optimize-bclasp
(progn
  ;;; Store the block environment, the push and the pop instructions for the block
  (defstruct (block-frame-info (:type vector))
    (needed nil)
    block-environment
    block-symbol
    make-block-frame-instruction
    #+debug-lexical-depth frame-unique-id
    #+debug-lexical-depth set-frame-unique-id
    initialize-block-closure-instruction)
  (defstruct (throw-return-from (:type vector))
    instruction
    #+debug-lexical-depth ensure-frame-unique-id
    depth start-env start-renv block-env block-symbol)
  (defvar *throw-return-from-instructions*))

#+optimize-bclasp
(progn
  (defstruct (tagbody-frame-info (:type vector))
    (needed nil)
    tagbody-environment
    make-tagbody-frame-instruction
    #+debug-lexical-depth setFrameUniqueId
    initialize-tagbody-closure)
  (defstruct (throw-dynamic-go (:type vector))
    instruction index depth start-env start-renv tagbody-env)
  (defvar *throw-dynamic-go-instructions*))

#+optimize-bclasp
(progn
  (defstruct (lexical-function-reference (:type vector))
    instruction index depth start-env start-renv function-env)
  (defvar *lexical-function-references*))


(defun generate-register-alloca (symbol env)
  (cv-log "Creating a register binding\n")
  (let* ((func-env (core:find-function-container-environment env))
         (entry-block (llvm-sys:get-entry-block (core:function-container-environment-function func-env)))
         (new-register (llvm-sys:insert-alloca-before-terminator %t*% (string symbol) entry-block)))
    new-register))


(defun binding-key (env index symbol)
  (list env index symbol))

(defun destructure-binding-key (key)
  (destructuring-bind (env index symbol)
      key
    (values env index symbol)))

(defun optimize-value-environments (refs)
  ;; env-ht stores a hash-table of environments to list of indices of
  ;;   closed-over variable indices
  (let ((variable-map (make-hash-table :test #'equal)))
    (dolist (ref refs)
      (let ((start-env (lexical-variable-reference-start-env ref))
            (index     (lexical-variable-reference-index ref))
            (symbol    (lexical-variable-reference-symbol ref))
            (depth     (lexical-variable-reference-depth ref)))
        (cv-log "Examining var %s  depth %s  index %s\n  env -> %s\n" symbol depth index start-env)
        (multiple-value-bind (ref-env crosses-function)
            (core:find-value-environment-at-depth start-env depth)
          (setf (lexical-variable-reference-ref-env ref) ref-env)
          (let ((key (binding-key ref-env index symbol)))
            (unless (eq :closure-allocate (gethash key variable-map))
              (setf (gethash key variable-map) (if crosses-function
                                                   :closure-allocate
                                                   :register-allocate)))))))
    ;; Now every variable (env . index) that is referenced is either in variable-map
    ;;    with the value :closure-allocate or :register-allocate
    (cv-log-do
     (maphash (lambda (k v)
                (bformat *debug-io* "(ENV@%s %s %s) -> %s\n" (core:environment-address (car k)) (second k) (third k) v))
              variable-map))
    (maphash (lambda (register-key option)
               (when (eq option :register-allocate)
                 (multiple-value-bind (env index symbol)
                     (destructure-binding-key register-key)
                   (let ((register (generate-register-alloca symbol env)))
                     (setf (gethash register-key variable-map) register)))))
             variable-map)
    (cv-log-do
     (maphash (lambda (k v)
                (bformat *debug-io* "(ENV@%s %s %s) -> %s\n" (core:environment-address (car k)) (second k) (third k) v))
              variable-map))
    variable-map))

(defun convert-to-register-access (register var-ref)
  (let* ((symbol (lexical-variable-reference-symbol var-ref))
         #+debug-lexical-depth(ensure-frame-unique-id (lexical-variable-reference-ensure-frame-unique-id var-ref)))
    (cv-log "Converting %s to a register register -> %s\n" symbol register)
    (multiple-value-bind (the-function primitive-info)
        (get-or-declare-function-or-error *the-module* "registerReference")
      (let ((the-function (get-or-declare-function-or-error *the-module* "registerReference"))
            (ignore-ensure-frame-unique-id (get-or-declare-function-or-error *the-module* "ignore_ensureFrameUniqueId"))
            (orig-instr (lexical-variable-reference-instruction var-ref)))
        (llvm-sys:replace-call the-function
                               orig-instr
                               (list register))
        #+debug-lexical-depth(llvm-sys:replace-call ignore-ensure-frame-unique-id
                                                    (first ensure-frame-unique-id)
                                                    nil)
        (cv-log "Finished replace call\n")))))

(defun convert-instructions-to-use-registers (refs variable-map)
  (dolist (var refs)
    (cv-log "Considering register rewrite for %s\n" (lexical-variable-reference-symbol var))
    (let* ((index (lexical-variable-reference-index var))
           (symbol (lexical-variable-reference-symbol var))
           (ref-env (lexical-variable-reference-ref-env var))
           (register-key (binding-key ref-env index symbol))
           (register (gethash register-key variable-map)))
      (when (not (closure-cell-p register))
        (convert-to-register-access register var)))))


(defun resize-closures-and-make-non-closures-invisible (new-value-environment-instructions
                                                        closure-environments)
  (maphash (lambda (environment env-maker)
             (let* ((new-env (value-frame-maker-reference-new-env env-maker))
                    (new-renv (value-frame-maker-reference-new-renv env-maker))
                    (instr (value-frame-maker-reference-instruction env-maker))
                    #+debug-lexical-depth (set-frame-unique-id (value-frame-maker-reference-set-frame-unique-id env-maker))
                    (closure-size (gethash new-env closure-environments)))
               (if closure-size
                   ;;rewrite the allocation to be the optimized size
                   (multiple-value-bind (the-function primitive-info)
                       (get-or-declare-function-or-error *the-module* "makeValueFrameSetParent")
                     (let* ((args (llvm-sys:call-or-invoke-get-argument-list instr))
                            (parent-renv (car (last args))))
                       (llvm-sys:replace-call the-function
                                              instr                                      
                                              (list (jit-constant-i64 closure-size) parent-renv))))
                   ;;(bformat *debug-io* "function-name -> %s\n" function-name)
                   (let ((the-function (get-or-declare-function-or-error *the-module* "invisible_makeValueFrameSetParent"))
                         #+debug-lexical-depth(ignore-set-frame-unique-id (get-or-declare-function-or-error *the-module* "ignore_setFrameUniqueId")))
                     (core:set-invisible new-env t)
                     (let* ((args (llvm-sys:call-or-invoke-get-argument-list instr))
                            (parent-renv (car (last args))))
                       (llvm-sys:replace-call the-function instr (list parent-renv))
                       #+debug-lexical-depth (funcall 'llvm-sys:replace-call
                                                      ignore-set-frame-unique-id
                                                      (car set-frame-unique-id)
                                                      nil))))))
           new-value-environment-instructions))

(defun rewrite-lexical-variable-references-for-new-depth (variable-map instructions)
  (dolist (ref instructions)
    (let* ((ref-env (lexical-variable-reference-ref-env ref))
           (index (lexical-variable-reference-index ref))
           #+debug-lexical-depth(ensure-frame-unique-id (lexical-variable-reference-ensure-frame-unique-id ref))
           (symbol (lexical-variable-reference-symbol ref))
           (key (binding-key ref-env index symbol))
           (var-info (gethash key variable-map)))
      (when (closure-cell-p var-info)
        (let* ((start-env (lexical-variable-reference-start-env ref))
               (depth (lexical-variable-reference-depth ref))
               (new-depth (core:calculate-runtime-visible-environment-depth start-env ref-env))
               (instr (lexical-variable-reference-instruction ref))
               (new-index (closure-cell-new-index var-info))
               (the-function (get-or-declare-function-or-error *the-module* "lexicalValueReference"))
               (ensure-frame-unique-id-function (get-or-declare-function-or-error *the-module* "ensureFrameUniqueId")))
          (cv-log "About to replace lexicalValueReference for %s  (old depth/index %d/%d)  (new depth/index %d/%d) to env %s  from env %s !!!!!!\n"
                  symbol depth index new-depth new-index (core:environment-address ref-env) start-env)
          #+(or)(progn
                  (bformat *debug-io* "In rewrite-lexical-variable-references-for-new-depth\n")
                  (bformat *debug-io* "         rewrite instruction before -> %s\n" instr)
                  (bformat *debug-io* "         arguments -> %s\n" (llvm-sys:call-or-invoke-get-argument-list instr)))
          (let* ((args (llvm-sys:call-or-invoke-get-argument-list instr))
                 (start-renv (car (last args)))
                 (new-instr (llvm-sys:replace-call the-function
                                                   instr
                                                   (list (jit-constant-size_t new-depth)
                                                         (jit-constant-size_t new-index)
                                                         start-renv))))
            #+debug-lexical-depth(let* ((instr (first ensure-frame-unique-id))
                                        (args (llvm-sys:call-or-invoke-get-argument-list instr)))
                                   (llvm-sys:replace-call ensure-frame-unique-id-function
                                                          instr
                                                          (list (first (second ensure-frame-unique-id))
                                                                (jit-constant-size_t new-depth)
                                                                (third args))))
            new-instr))))))

(defun rewrite-return-from-for-new-depth (instructions)
  (dolist (return-from instructions)
    (let ((instr (throw-return-from-instruction return-from))
          (old-depth (throw-return-from-depth return-from))
          (start-env (throw-return-from-start-env return-from))
          (block-env (throw-return-from-block-env return-from)))
      (let ((new-depth (core:calculate-runtime-visible-environment-depth start-env block-env)))
        (let ((the-function (get-or-declare-function-or-error *the-module* "throwReturnFrom"))
              #+debug-lexical-depth(ensure-frame-unique-id-function (get-or-declare-function-or-error *the-module* "ensureFrameUniqueId")))
          (cv-log "About to replace call to %s\n" the-function)
          (let* ((args (llvm-sys:call-or-invoke-get-argument-list instr))
                 (start-renv (car (last args))))
            (llvm-sys:replace-call the-function
                                   instr
                                   (list (jit-constant-size_t new-depth)
                                         start-renv))
            #+debug-lexical-depth(let* ((info (throw-return-from-ensure-frame-unique-id return-from))
                                        (instr (first info))
                                        (old-args (second info))
                                        (args (llvm-sys:call-or-invoke-get-argument-list instr)))
                                   (llvm-sys:replace-call ensure-frame-unique-id-function
                                                          instr
                                                          (list (first old-args)
                                                                (jit-constant-size_t new-depth)
                                                                (third args)))))
          (cv-log "Done\n"))))))

(defun rewrite-dynamic-go-for-new-depth (instructions)
  (dolist (go instructions)
    (let ((index (throw-dynamic-go-index go))
          (instr (throw-dynamic-go-instruction go))
          (old-depth (throw-dynamic-go-depth go))
          (start-env (throw-dynamic-go-start-env go))
          (tagbody-env (throw-dynamic-go-tagbody-env go)))
      (let ((new-depth (core:calculate-runtime-visible-environment-depth start-env tagbody-env)))
        (multiple-value-bind (the-function primitive-info)
            (get-or-declare-function-or-error *the-module* "throwDynamicGo")
          (cv-log "About to replace call to %s\n" the-function)
          (let* ((args (llvm-sys:call-or-invoke-get-argument-list instr))
                 (start-renv (car (last args))))
            (llvm-sys:replace-call the-function
                                   instr
                                   (list (jit-constant-size_t new-depth)
                                         (jit-constant-size_t index)
                                         start-renv))))
        (cv-log "Done\n")))))

(defstruct (track-rewrites (:type vector) :named)
  (total 0)
  (ignored 0)
  (mutex (mp:make-lock :name 'rewrites)))

(defvar *block-rewrite-counter* (make-track-rewrites)
  "Keep track of block special operators that were seen and those that were rewritten to be ignored")
  
(defparameter *rewrite-blocks* t)
(defun rewrite-blocks-with-no-return-froms (block-info)
  (when *rewrite-blocks*
    (let ((ignore-make-block-frame-function (get-or-declare-function-or-error *the-module* "invisible_makeBlockFrameSetParent"))
          (ignore-initialize-block-closure-function (get-or-declare-function-or-error *the-module* "ignore_initializeBlockClosure"))
          #+debug-lexical-depth(ignore-set-frame-unique-id (get-or-declare-function-or-error *the-module* "ignore_setFrameUniqueId")))
      (let ((total 0)
            (ignored 0))
        (maphash (lambda (env block-info)
                   (incf total)
                   (unless (block-frame-info-needed block-info)
                     (incf ignored)
                     (core:set-invisible (block-frame-info-block-environment block-info) t)
                     (funcall 'llvm-sys:replace-call-keep-args ignore-make-block-frame-function
                            (car (block-frame-info-make-block-frame-instruction block-info)))
                     (funcall 'llvm-sys:replace-call-keep-args
                            ignore-initialize-block-closure-function
                            (car (block-frame-info-initialize-block-closure-instruction block-info)))
                     #+debug-lexical-depth(funcall 'llvm-sys:replace-call
                                                   ignore-set-frame-unique-id
                                                   (car (block-frame-info-set-frame-unique-id block-info))
                                                   nil)))
                 block-info)
        (unwind-protect
             (progn
               (mp:get-lock (track-rewrites-mutex *block-rewrite-counter*) nil)
               (let ((total-sum (+ (track-rewrites-total *block-rewrite-counter*) total))
                     (ignored-sum (+ (track-rewrites-ignored *block-rewrite-counter*) ignored)))
                 (setf (track-rewrites-total *block-rewrite-counter*) total-sum)
                 (setf (track-rewrites-ignored *block-rewrite-counter*) ignored-sum)))
          (mp:giveup-lock (track-rewrites-mutex *block-rewrite-counter*)))
        (cv-log "Done\n")))))

(defvar *tagbody-rewrite-counter* (make-track-rewrites)
  "Keep track of tagbody special operators that were seen and those that were rewritten to be ignored")
  
(defparameter *rewrite-tagbody* t)
(defun rewrite-tagbody-with-no-go (tagbody-info)
  (when *rewrite-tagbody*
    (let ((ignore-make-tagbody-frame-function (get-or-declare-function-or-error *the-module* "invisible_makeTagbodyFrameSetParent"))
          (ignore-initialize-tagbody-closure-function (get-or-declare-function-or-error *the-module* "ignore_initializeTagbodyClosure")))
      (let ((total 0)
            (ignored 0))
        (maphash (lambda (env tagbody-info)
                   (incf total)
                   (unless (tagbody-frame-info-needed tagbody-info)
                     (incf ignored)
                     (core:set-invisible (tagbody-frame-info-tagbody-environment tagbody-info) t)
                     (funcall 'llvm-sys:replace-call-keep-args ignore-initialize-tagbody-closure-function
                            (car (tagbody-frame-info-initialize-tagbody-closure tagbody-info)))
                     (funcall 'llvm-sys:replace-call-keep-args ignore-make-tagbody-frame-function
                              (car (tagbody-frame-info-make-tagbody-frame-instruction tagbody-info)))))
                 tagbody-info)
        (unwind-protect
             (progn
               (mp:get-lock (track-rewrites-mutex *tagbody-rewrite-counter*) nil)
(let ((total-sum (+ (track-rewrites-total *tagbody-rewrite-counter*) total))
                     (ignored-sum (+ (track-rewrites-ignored *tagbody-rewrite-counter*) ignored)))
                 (setf (track-rewrites-total *tagbody-rewrite-counter*) total-sum)
                 (setf (track-rewrites-ignored *tagbody-rewrite-counter*) ignored-sum)))
          (mp:giveup-lock (track-rewrites-mutex *tagbody-rewrite-counter*)))
        (cv-log "Done\n")))))

(defun rewrite-lexical-function-references-for-new-depth (lexical-function-references)
  (dolist (funcref lexical-function-references)
    (let ((index (lexical-function-reference-index funcref))
          (instr (lexical-function-reference-instruction funcref))
          (old-depth (lexical-function-reference-depth funcref))
          (start-env (lexical-function-reference-start-env funcref))
          (function-env (lexical-function-reference-function-env funcref)))
      (let ((new-depth (core:calculate-runtime-visible-environment-depth start-env function-env)))
        (multiple-value-bind (the-function primitive-info)
            (get-or-declare-function-or-error *the-module* "va_lexicalFunction")
          (cv-log "About to replace call to %s\n" instr)
          (let* ((args (llvm-sys:call-or-invoke-get-argument-list instr))
                 (start-renv (car (last args))))
            (llvm-sys:replace-call the-function
                                   instr
                                   (list (jit-constant-size_t new-depth)
                                         (jit-constant-size_t index)
                                         start-renv))))))))

(defun optimize-closures (variable-map make-value-environment-instructions)
  (let ((closure-environments (make-hash-table)))
    (maphash (lambda (key value)
               (when (eq value :closure-allocate)
                 (multiple-value-bind (env index symbol)
                     (destructure-binding-key key)
                   (let ((new-index (gethash env closure-environments nil)))
                     (if (null new-index)
                         (setf (gethash env closure-environments) 1
                               new-index 0)

                         (setf (gethash env closure-environments) (+ 1 (gethash env closure-environments))))
                     (setf (gethash key variable-map)
                           (make-closure-cell :environment env
                                              :old-index index
                                              :new-index new-index
                                              :symbol symbol))))))
             variable-map)
    ;; Rewrite the non-closure value-frames to make them invisible
    ;; and resize the closure value-frames
    (resize-closures-and-make-non-closures-invisible make-value-environment-instructions
                                                     closure-environments)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Carry out a collection of optimization passes on the LLVM-IR
;;;   after codegen that is done in the body.
;;; In other words - the bclasp compiler in 'body' codegens a top-level form
;;;   and gathers information in the dynamic variables bound below.
;;;   Then the optimization passes after 'body' operate on the llvm-ir in
;;;   the passes:
;;;      optimize-closures - identifies lexical variables that must be closures
;;;      rewrite-lexical-variable-references-for-new-depth -
;;;              rewrites closed over lexical variable access to account
;;;              for activation frames that are now not necessary
;;;      rewrite-dynamic-go-for-new-depth - rewrites dynamic-go instructions
;;;              to account for the activation frames that are not necessary
;;;      rewrite-return-from-for-new-depth - rewrites return-from instructions
;;;              to account for the activation frames that are not necessary
;;;      rewrite-lexical-function-references-for-new-depth -
;;;              rewrites lexical function references to account for the
;;;              activation frames that are no longer necessary.
;;;      convert-instructions-to-use-registers - converts lexical variable
;;;              references that are not closed over to use registers and allocas
;;;
;;;   These optimizations take time - and when the interpreter is starting up
;;;     they may take more time than they take to run.
;;;     They can be turned off using *activation-frame-optimize* (NIL is off)
;;;
;;;  The cmp::*activation-frame-optimize* variable is defined in init.lsp
;;;      and it's temporarily bound to NIL in clasp-builder.lsp
(defmacro with-lexical-variable-optimizer ((optimize) &rest body)
  #-optimize-bclasp`(progn ,@body)
  #+optimize-bclasp
  (let ((variable-map (gensym)))
    `(let ((*lexical-variable-references* nil)
           (*make-value-frame-instructions* (make-hash-table))
           (*throw-dynamic-go-instructions* nil)
           (*tagbody-frame-info* (make-hash-table))
           (*throw-return-from-instructions* nil)
           (*block-frame-info* (make-hash-table))
           (*lexical-function-references* nil)
           (*lexical-function-frame-makers* nil))
       (multiple-value-prog1 (progn ,@body)
         (when (and ,optimize *activation-frame-optimize*)
           (let ((,variable-map (optimize-value-environments *lexical-variable-references*)))
             (progn
               (cv-log "optimize-closures ,variable-map \n")
               ;; Identify activation frame/environments that must be closures
               ;; and optimize all other references to use alloca's in the stack frame
               (optimize-closures ,variable-map *make-value-frame-instructions*)
               (progn
                 ;; Rewrite block instructions to ignore those that don't have return-froms
                 (cv-log "rewrite-blocks-with-no-return-froms \n")
                 (rewrite-blocks-with-no-return-froms *block-frame-info*)
                 ;; Rewrite tagbody environment instructions to ignore those that don't have go's
                 (cv-log "rewrite-tagbody-with-no-go \n")
                 (rewrite-tagbody-with-no-go *tagbody-frame-info*)))
             (progn
               ;; Rewrite throwReturnFrom instructions to take into account the newly invisible environments
               (cv-log "rewrite-return-from-for-new-depth \n")
               (rewrite-return-from-for-new-depth *throw-return-from-instructions*)
               ;; Rewrite lexicalDynamicGo instructions to take into account the newly invisible environments
               (cv-log "rewrite-dynamic-go-for-new-depth \n")
               (rewrite-dynamic-go-for-new-depth *throw-dynamic-go-instructions*)
               ;; Rewrite lexicalFunction references to take into account the newly invisible environments
               (cv-log "rewrite-lexical-function-references-for-new-depth \n")
               (rewrite-lexical-function-references-for-new-depth *lexical-function-references*)
               ;; Rewrite lexical variable references to take into account the newly invisible environments
               (cv-log "rewrite-lexical-variable-references-for-new-depth \n")
               (rewrite-lexical-variable-references-for-new-depth ,variable-map *lexical-variable-references*)
               (cv-log "convert-instructions-to-use-registers \n")
               (convert-instructions-to-use-registers *lexical-variable-references* ,variable-map))))))))

;;
;; variable lookups are in this file so we can compile-file it first and make 
;; compilation faster
;;

(defun codegen-special-var-lookup (result sym env)
  "Return IR code that returns the value cell of a special symbol"
  (cmp-log "About to codegen-special-var-lookup symbol[%s]\n" sym)
  (if (eq sym 'nil)
      (codegen-literal result nil env)
      (let* ((global-symbol (irc-global-symbol sym env))
             (val (irc-intrinsic "symbolValueRead" global-symbol)))
        (irc-store val result))))


#+(or)
(defun codegen-local-lexical-var-reference (index renv)
  "Generate code to reference a lexical variable in the current value frame"
  (or (equal (llvm-sys:get-type renv) %afsp*%)
      (error "renv is not the right type %afsp*%, it is: ~a" (llvm-sys:get-type renv)))
  (let* ((value-frame-tsp           (irc-load renv))
         (tagged-value-frame-ptr    (llvm-sys:create-extract-value *irbuilder* value-frame-tsp (list 0) "tagged-value-frame-ptr"))
         (as-uintptr_t              (irc-ptr-to-int tagged-value-frame-ptr %uintptr_t% ""))
         (general-pointer-tag       (cdr (assoc :general-tag cmp::+cxx-data-structures-info+)))
         (no-tag-uintptr_t          (llvm-sys:create-sub cmp:*irbuilder* as-uintptr_t (jit-constant-uintptr_t general-pointer-tag) "value-frame-no-tag" nil nil))
         (element0-offset           (cdr (assoc :value-frame-element0-offset cmp::+cxx-data-structures-info+)))
         (general-pointer-tag       (cdr (assoc :general-tag cmp::+cxx-data-structures-info+)))
         (element-size              (cdr (assoc :value-frame-element-size cmp::+cxx-data-structures-info+)))
         (offset                    (+ element0-offset (* element-size index)))
         (entry-uintptr_t           (llvm-sys:create-add cmp:*irbuilder* no-tag-uintptr_t (jit-constant-uintptr_t offset)))
         (entry-ptr                 (irc-int-to-ptr entry-uintptr_t %tsp*% (core:bformat nil "frame[%s]-ptr" index))))
    entry-ptr))

#+(or)
(defun codegen-parent-frame-lookup (renv)
  (let* ((value-frame-tsp        (irc-load          renv))
         (tagged-value-frame-ptr (irc-extract-value value-frame-tsp (list 0) "pfl-tagged-value-frame-ptr"))
         (as-uintptr-t           (irc-ptr-to-int    tagged-value-frame-ptr %uintptr_t% "pfl-as-uintptr-t"))
         (parent-uintptr         (irc-add           as-uintptr-t (jit-constant-uintptr_t (- +value-frame-parent-offset+ +general-tag+)) "pfl-no-tag-uintptr"))
         (parent-ptr             (irc-int-to-ptr    parent-uintptr %afsp*% "pfl-parent-ptr")))
    parent-ptr))



;;; ------------------------------------------------------------
;;;
;;; Add :debug-lexical-var-reference-depth to *features* to get a report
;;; on the number of times lexical variables are accessed from different
;;; activation frame depths.  This will help inform me (meister) if
;;; I need to add more code to access activation frames.
#+debug-lexical-var-reference-depth
(eval-when (:compile-toplevel :execute)
  (cv-log "keeping track of lexical var reference depth - remove this code for production\n")
  (defvar *lexical-var-reference-counter* (make-hash-table :test #'eql))
  (defun record-lexical-var-reference-depth (depth)
    (let ((cur (gethash depth *lexical-var-reference-counter* 0)))
      (core:hash-table-setf-gethash *lexical-var-reference-counter* depth (+ cur 1))))
  (defun report-lexical-var-reference-depth ()
    (cv-log "Lexical-var-reference-depth references\n")
    (let (results)
      (maphash (lambda (depth count)
                 (push (cons depth count) results))
               *lexical-var-reference-counter*)
      (let ((counts (sort results #'< :key #'car)))
        (dolist (entry counts)
          (core:bformat t "Depth %d -> %d references\n" (car entry) (cdr entry)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Two choices for codegen-lexical-var-reference
(defun codegen-lexical-var-reference (symbol depth index start-env dest-env)
  ;;     The top one generates code to access the lexical-var references
  ;;      in activation frames as quickly as possible but cannot use registers
  ;; This second option saves information that can be used later to convert local lexical variables into allocas
  (let* ((start-renv (irc-load (irc-renv start-env)))
         #+debug-lexical-depth (info (gethash dest-env *make-value-frame-instructions*))
         #+debug-lexical-depth (frame-unique-id (value-frame-maker-reference-frame-unique-id info))
         #+debug-lexical-depth (ensure-frame-unique-id (irc-intrinsic "ensureFrameUniqueId"
                                                                      (jit-constant-size_t frame-unique-id)
                                                                      (jit-constant-size_t depth)
                                                                      (irc-load (irc-renv start-env))))
         (instruction (irc-intrinsic "lexicalValueReference" (jit-constant-size_t depth) (jit-constant-size_t index) start-renv)))
    #+optimize-bclasp(push (make-lexical-variable-reference :symbol symbol
                                                            :start-env start-env
                                                            :start-renv start-renv
                                                            :depth depth
                                                            :index index
                                                            :instruction instruction
                                                            #+debug-lexical-depth :ensure-frame-unique-id #+debug-lexical-depth (list ensure-frame-unique-id (list (jit-constant-size_t frame-unique-id)
                                                                                                                                                                   (jit-constant-size_t depth)
                                                                                                                                                                   (irc-load (irc-renv start-env))) ))
                           *lexical-variable-references*)
    instruction))

(defun codegen-lexical-var-lookup (result symbol depth index src-env dest-env)
  "Generate IR for lookup of lexical value in runtime-env using depth and index"
  (dbg-set-current-debug-location-here)
  (let* ((ref (codegen-lexical-var-reference symbol depth index src-env dest-env))
         (val (irc-load ref "lexical-value-load")))
    (irc-store val result))
  result)

(defun codegen-register-var-lookup (result alloca)
  ;; Read from a register
  (let ((val (irc-load alloca)))
    (irc-store val result)))

(defun codegen-var-lookup (result sym src-env)
  "Return IR code thsym returns the value of a symbol that is either lexical or special"
  (let ((classified (variable-info src-env sym)))
    (cmp-log "About to codegen-var-lookup for %s - classified as: %s  env->%s\n" sym classified src-env)
    (cond
      ((eq (car classified) 'ext:special-var)
       (codegen-special-var-lookup result sym src-env))
      ((eq (car classified) 'ext:lexical-var)
       (let ((symbol (second classified))
             (depth (third classified))
             (index (fourth classified))
             (dest-env (fifth classified)))
         (codegen-lexical-var-lookup result symbol depth index src-env dest-env)))
      ((eq (car classified) 'ext:register-var)
       (cv-log "classified  register-var -> %s\n" classified)
       (codegen-register-var-lookup result (cdr classified)))
      (t (error "Handle codegen-var-lookup with ~s" classified)))))

(defun codegen-symbol-value (result symbol env)
  (cmp-log "codegen-symbol-value  symbol -> %s\n" symbol)
  (if (keywordp symbol)
      (progn
        (cmp-log "codegen-symbol-value - %s is a keyword\n" symbol)
        (irc-store (irc-intrinsic "symbolValueRead" (irc-global-symbol symbol env)) result))
      (progn
        (cmp-log "About to macroexpand\n")
        (let ((expanded (macroexpand symbol env)))
          (cmp-log "codegen-symbol-value - %s is not a keyword\n" symbol)
          (if (eq expanded symbol)
              ;; The symbol is unchanged, look up its value
              (codegen-var-lookup result symbol env)
              ;; The symbol was a symbol-macro - evaluate it
              (codegen result expanded env)
              )))))
	
(defun compile-save-if-special (env target &key make-unbound)
  (when (eq (car target) 'ext:special-var)
    (cmp-log "compile-save-if-special - the target: %s is special - so I'm saving it\n" target)
    (let* ((target-symbol (cdr target))
	   (irc-target (irc-global-symbol target-symbol env)))
      (irc-intrinsic "pushDynamicBinding" irc-target) ; was (irc-load irc-target)
      (when make-unbound
	(irc-intrinsic "makeUnboundTsp" (irc-intrinsic "symbolValueReference" irc-target)))
      (irc-push-unwind env `(symbolValueRestore ,target-symbol))
      ;; Make the variable locally special
      (value-environment-define-special-binding env target-symbol))))


(defmacro with-target-reference-do ((target-ref target env) &rest body)
  "This function generates code to write val into target
\(special-->Symbol value slot or lexical-->ActivationFrame) at run-time.
Use cases:
- generate code to copy a value into the target-ref
\(with-target-reference-do (target-ref target env)
  (irc-intrinsic \"copyTsp\" target-ref val))
- compile arbitrary code that writes result into the target-ref
\(with-target-reference-do (target-ref target env)
  (codegen target-ref form env))"
  `(progn
     (let ((,target-ref (compile-target-reference* ,env ,target)))
       ,@body)
     ;; Add the target to the ValueEnvironment AFTER storing it in the target reference
     ;; otherwise the target may shadow a variable in the lexical environment
     (define-binding-in-value-environment* ,env ,target)
     ))

(defmacro with-target-reference-no-bind-do ((target-ref target env) &rest body)
  "This function generates code to write val into target
\(special-->Symbol value slot or lexical-->ActivationFrame) at run-time.
Use cases:
- generate code to copy a value into the target-ref
\(with-target-reference-do (target-ref target env)
  (irc-intrinsic \"copyTsp\" target-ref val))
- compile arbitrary code that writes result into the target-ref
\(with-target-reference-do (target-ref target env)
  (codegen target-ref form env))"
  `(progn
     (let ((,target-ref (compile-target-reference* ,env ,target)))
       ,@body)
     ;; Add the target to the ValueEnvironment AFTER storing it in the target reference
     ;; otherwise the target may shadow a variable in the lexical environment
;;     (define-binding-in-value-environment* ,env ,target)
     ))



(defmacro with-target-reference-if-runtime-unbound-do ((target-ref target env) &rest body)
  "Generate code that does everything with-target-reference-do does
but tests if the value in target-ref is unbound and if it is only-then evaluate body which
will put a value into target-ref."
  (let ((i1-target-is-bound-gs (gensym))
	(unbound-do-block-gs (gensym))
	(unbound-cont-block-gs (gensym)))
    `(progn
       (with-target-reference-do (,target-ref ,target ,env)
	 (let ((,i1-target-is-bound-gs (irc-trunc (irc-intrinsic "isBound" (irc-load ,target-ref)) %i1%))
	       (,unbound-do-block-gs (irc-basic-block-create "unbound-do"))
	       (,unbound-cont-block-gs (irc-basic-block-create "unbound-cont"))
	       )
	   (irc-cond-br ,i1-target-is-bound-gs ,unbound-cont-block-gs ,unbound-do-block-gs)
	   (irc-begin-block ,unbound-do-block-gs)
	   ,@body
	   (irc-br ,unbound-cont-block-gs)
	   (irc-begin-block ,unbound-cont-block-gs)
	   ))
       ;; Add the target to the ValueEnvironment AFTER storing it in the target reference
       ;; otherwise the target may shadow a variable in the lexical environment
       (define-binding-in-value-environment* ,env ,target)
       )))

(defun compile-target-reference* (env target)
  "This function determines if target is special or lexical and generates
code to get the reference to the target.
It then returns (values target-ref target-type target-symbol target-lexical-index).
If target-type=='special-var then target-lexical-index will be nil.
You don't want to only write into the target-reference because
you need to also bind the target in the compile-time environment "
  (cmp-log "compile-target-reference target[%s]\n" target)
  (cond
    ((eq (car target) 'ext:special-var)
     (cmp-log "compiling as a special-var\n")
     (values (irc-intrinsic "symbolValueReference" (irc-global-symbol (cdr target) env))
	     (car target)		; target-type --> 'special-var
	     (cdr target)		; target-symbol
	     ))
    ((eq (car target) 'ext:lexical-var)
     (cmp-log "compiling as a ext:lexical-var\n")
     (values (codegen-lexical-var-reference (second target) 0 #|<-depth|# (cddr target) env env)
	     (car target)           ; target-type --> 'ext:lexical-var
	     (cadr target)          ; target-symbol
	     (cddr target)          ; target-lexical-index
	     ))
    (t (error "Illegal target type[~a] for argument" target))))

(defun define-binding-in-value-environment* (env target)
  "Define the target within the ValueEnvironment in env.
If the target is special then define-special-binding.
If the target is lexical then define-lexical-binding."
  (cmp-log "define-binding-in-value-environment for target: %s\n" target)
  (cond
    ((eq (car target) 'ext:special-var)
     (let ((target-symbol (cdr target)))
       (value-environment-define-special-binding env target-symbol)))
    ((eq (car target) 'ext:lexical-var)
     (let ((target-symbol (cadr target))
	   (target-lexical-index (cddr target)))
       (value-environment-define-lexical-binding env target-symbol target-lexical-index)))
    (t (error "Illegal target-type ~a" (car target))))
)

