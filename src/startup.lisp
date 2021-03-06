;; There are two entry points for Emotiq - development and binary (production).
;;
;; At the moment, we favor development activities over binary building.  Developers
;  should be able to load-and-go.  The MAIN entry point is an example of what developers
;  might use.  MAIN does nothing, but test whether make-key-pair doesn't crash.
;; 
;; When building binaries, we use the DELIVER function.  This function cannot
;  run with multitasking turned on, but it can create a binary which runs
;  with multitasking turned on.  In Emotiq code, multitasking is required
;  by the Actors system.  This means that the Actors code cannot be initialized
;  during construction of a binary.  This "special case" is handled only in
;  the binary construction code.  A binary must install and initialize the Actors
;  system during startup.  The START function is called by a binary, as its
;  entry point.  During the building of a binary, emotiq/etc/deliver/deliver.lisp
;  sets a special variable (cl-user::*performing-binary-build*) to any value
;  (as long as BOUNDP returns T on this special).  The START function
;  must set EMOTIQ::*production* to T, which is used in emotiq/src/Crypto/pbc-cffi.lisp
;  via the function EMOTIQ:PRODUCTION-P to initialize DLL's at runtime.  
;
;; We allow developers to use Lisp LOAD to initialize various parts of the
;; system (including Actors).  When building the binary, we need to explicitly
;; initialize Actors.

(in-package "EMOTIQ")

(defun main (&key etc-and-wallets how-started-message?)
  "Main loop for Emotiq daemon"
  (emotiq/random:init-random) ;; after calling this, (RANDOM 100) will return the same sequence of pseudo-random numbers on each test run 
  (core-crypto:startup)
  (setf gossip::*debug-level* nil)
  (when etc-and-wallets
    (setf (symbol-function 'emotiq/fs:etc/)
          (lambda () (pathname etc-and-wallets))))
  (message-running-state how-started-message?)

  ;; Create a default wallet on disk if one doesn't already exist
  (emotiq/wallet:create-wallet)

  ;; Start the websocket interface for the Electron wallet
  ;; listening <ws://localhost:PORT/wallet> .
  (when (string-equal "true"
                      (emotiq/config:setting :websocket-server))
    (websocket/wallet:start-server :port (emotiq/config:setting :websocket-server-port)))

  ;; Start the REST server which provides support for testing the
  ;; WebSocket implementation at <http://localhost:PORT/client/>
  (when (string-equal "true"
                      (emotiq/config:setting :rest-server))
    (emotiq-rest:start-server :port (emotiq/config:setting :rest-server-port)))

  (emotiq/tracker:start-tracker)
  (emotiq:start-node)
  (cosi-simgen:startup-elections))

;; Entry Point for binary (aka "production" version of the system.
(defun start ()
  ;; This is for running in the binary command line only. For now, if we're
  ;; starting from the command line, we assume it's for
  ;; production. Later, we'll have other means of setting
  ;; *production*. TEMPORARY! FIX! 4/6/18
  ;; ^^ in this context "production" ONLY means binary build.
  (unintern 'cl-user::*performing-binary-build*) ;; if building binary,
  (setq *production* t)  ;; used by EMOTIQ:PRODUCTION-P in Crypto
  (message-running-state "from command line")
  ;(core-crypto:startup)
  (actors:install-actor-system)
  (main))

(defun argv ()
#+lispworks system:*line-arguments-list*
#+OPENMCL ccl:*command-line-argument-list*)

(defun message-running-state (&optional how-started-message?)
  (format *standard-output* "~%Running ~a in ~a~%with args [~a]~%"
          (or how-started-message? "interactively")
          (if (production-p) "production" "development")
	  (argv)))




