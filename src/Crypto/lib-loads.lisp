
(defpackage :crypto-lib-loader
  (:use :cl)
  (:export
   :load-dlls
   :unload-dlls
   ))

(in-package :crypto-lib-loader)

;; -----------------------------------------------------------------------

;; The Lisp runtime load might help us do this differently, but explicit
;; initialization is much easier to understand

(defun define-dev-dlls ()
  "loads the DLLs (.so and .dylib) at runtime, from pre-specified directories"
  (pushnew (asdf:system-relative-pathname :emotiq "../var/local/lib/")
           cffi:*foreign-library-directories* :test 'equal)
  (cffi:define-foreign-library
      :libEd3363 
    (:darwin     "libLispEd3363.dylib")
    (:linux      "libLispEd3363.so")
    (t (:default "libLispEd3363")))
  (cffi:define-foreign-library
      :libCurve1174
    (:darwin     "libLispCurve1174.dylib")
    (:linux      "libLispCurve1174.so")
    (t (:default "libLispCurve1174")))
  (cffi:define-foreign-library
      :libLispPBC 
    (:darwin     "libLispPBCIntf.dylib")
    (:linux      "libLispPBCIntf.so")
    (t (:default "libLispPBCIntf"))))

(defun define-production-dlls ()
  "loads the DLLs (.so and .dylib) at runtime, from the current directory"
  (cffi:define-foreign-library
      :libEd3363
   (:darwin     "libLispEd3363.dylib")
   (:linux      "libLispEd3363.so")
   (t (:default "libLispEd3363")))
  (cffi:define-foreign-library
      :libCurve1174
   (:darwin     "libLispCurve1174.dylib")
   (:linux      "libLispCurve1174.so")
   (t (:default "libLispCurve1174")))
  (cffi:define-foreign-library
      :libLispPBC
   (:darwin     "libLispPBCIntf.dylib")
   (:linux      "libLispPBCIntf.so")
   (t (:default "libLispPBCIntf"))))

(defvar *load-counter*  0)

(defun load-dlls ()
  "load the dev or production dlls at runtime"
  (format t "~%CRYPTO-LIB-LOADER:LOAD-DLL Load Counter = ~A" (incf *load-counter*))
  (cond
   ((= 1 *load-counter*)
    (if (emotiq:production-p)
        (define-production-dlls)
      (define-dev-dlls))
    ;; (format t "DYLD_LIBRARY_PATH = ~S" (getenv "DYLD_LIBRARY_PATH"))
    (format t "~%cffi:*foreign-library-directories* = ~S"
            (mapcar (lambda (item)
                      (if (consp item)
                          (apply (first item) (rest item))
                        item))
                    cffi:*foreign-library-directories*))
    (cffi:use-foreign-library :libLispPBC)
    (cffi:use-foreign-library :libEd3363)
    (cffi:use-foreign-library :libCurve1174))
   
   (t
    (format t "~%Skipping library loading"))
   ))

(defun unload-dlls ()
  (cffi:close-foreign-library :libLispPBC)
  (cffi:close-foreign-library :libed3363)
  (cffi:close-foreign-library :libcurve1174)
  (setf *load-counter* 0))
  
(load-dlls)
