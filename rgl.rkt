#lang racket/base

(require 
  racket/promise racket/future racket/include racket/set 
  (rename-in racket/contract (-> ->>))
  ffi/unsafe ffi/vector)

(define stype (system-type))

(define gl-lib 
  (delay 
    (case stype
      [(windows) (ffi-lib "opengl32")]
      [(macosx) (ffi-lib "/System/Library/Frameworks/OpenGL.framework/Versions/A/Libraries/libGL")]
      [else (ffi-lib "libGL" '("1" ""))])))

(define windows? (eq? 'windows stype))

(define win32?
  (and windows?
       (equal? "win32\\i386" (path->string (system-library-subpath #f)))))

(define-syntax _fun*
  (syntax-rules ()
    [(_fun* x ...)
     (if win32? (_fun #:abi 'stdcall x ...) (_fun x ...))]))


;; The getProcAddress procedure dynamically loads a GL procedure.
(define getProcAddress 
  (delay 
    (if windows?
      (get-ffi-obj "wglGetProcAddress" (force gl-lib) (_fun* _string -> _pointer)
                   (lambda () (lambda (x) #f)))
      ; According to the Linux ABI, the correct entry point is glXGetProcAddressARB.
      ; But let's try the non-ARB version too.
      (get-ffi-obj "glXGetProcAddressARB" (force gl-lib) (_fun _string -> _pointer)
                   (lambda ()
                     (get-ffi-obj "glXGetProcAddress" (force gl-lib) (_fun _string -> _pointer)
                                  (lambda () (lambda (x) #f))))))))

(define (make-undefined-procedure name)
;  (printf "OpenGL procedure not available: ~a~%" name)
  (lambda args
    (error "OpenGL procedure not available:" name)))

(define (lookup-gl-procedure name type)
  (get-ffi-obj name (force gl-lib) type
               (lambda ()
                 (let ((ptr ((force getProcAddress) (symbol->string name))))
                   (if ptr
                     (begin
;                       (printf "Loaded dynamically: ~a~%" name)
                       (function-ptr ptr type))
                     (make-undefined-procedure name))))))

; Load everything lazily.
; This speeds things up in general and is essential on Windows
; where GL procedures can only be looked up once a GL context is bound.
(define (create-gl-procedure name arity type)
  (let ((proc (delay (lookup-gl-procedure name type))))
    (procedure-rename
      (procedure-reduce-arity
        (lambda args (apply (force proc) args))
        arity)
      name)))

(define-syntax define-gl
  (syntax-rules ()
   ((_ name arity (type ...) contract)
    (begin
      (define name (create-gl-procedure 'name arity (_fun* type ...)))
      (provide/contract (name contract))))))

(include "generated/gl_specs.rkt")

(define (split-spaces str)
  (regexp-split #px"\\s+" str))

;; Query information in a convenient way.
;(provide gl-version gl-extensions gl-has-extension?)
(provide/contract 
  (gl-version (->> (listof exact-integer?)))
  (gl-extensions (->> set-eq?))
  (gl-has-extension? (->> symbol? boolean?)))

(define gl-version
  (let ((version 
          (delay 
            (map string->number
                 (regexp-split #px"\\."
                               (car (split-spaces (glGetString GL_VERSION))))))))
    (lambda () (force version))))

(define gl-extensions
  (let ((extensions (delay
                      (for/seteq ((ext (in-list (split-spaces (glGetString GL_EXTENSIONS)))))
                                 (string->symbol ext)))))
    (lambda () (force extensions))))

(define (gl-has-extension? ext)
  (set-member? (gl-extensions) ext))

; A "gl-vector" is any homogenous vector of a type which is used with the OpenGL API.
(provide/contract (gl-vector? (->> any/c boolean?)))

(define (gl-vector? obj)
  (or (bytes? obj) (s8vector? obj) (u16vector? obj) (s16vector? obj)
      (u32vector? obj) (s32vector? obj) (f32vector? obj) (f64vector? obj)))


;; Get the appropriate type enum for a Racket vector.
;; Useful for glVertexPointer and friends.
(provide/contract (gl-vector->type (->> gl-vector? exact-integer?)))

(define (gl-vector->type vec)
  (cond
    ((bytes? vec) GL_UNSIGNED_BYTE)
    ((s8vector? vec) GL_BYTE)
    ((u16vector? vec) GL_UNSIGNED_SHORT)
    ((s16vector? vec) GL_SHORT)
    ((u32vector? vec) GL_UNSIGNED_INT)
    ((s32vector? vec) GL_INT)
    ((f32vector? vec) GL_FLOAT)
    ((f64vector? vec) GL_DOUBLE)))