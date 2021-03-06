;;; gossip.lisp
;;; 11-May-2018 SVS

;;; Actor-based gossip protocol.
;;; As far as the actors are concerned,
;;; we're just sending messages of type :gossip, regardless of whether they're solicitations
;;; or replies.
;;; Gossip messages are simply sent as payload of a lower-level actor message.

;;;; TODO:
;;;; Change things such that when forward-to is an integer, if a node gets an active ignore back from
;;;;  neighbor X, it should pick another neighbor if it has more available.

;;;; NOTES: "Upstream" means "back to the solicitor: the node that sent me a solicitation in the first place"

(in-package :gossip)

(defconstant +default-graphid+ :root "Identifier of the default, root, ground, or 'physical' graph that a node is always part of")

(defparameter *default-uid-style* :short ":tiny, :short, or :long. :short is shorter; :long is more comparable with other emotiq code.
       :tiny should only be used for testing, documentation, and graph visualization of nodes on a single machine since it creates extremely short UIDs
        that are not expected to be globally-unique.")
(defparameter *max-message-age* (truncate 300e6) "Messages older than this number of microseconds will be ignored")
(defparameter *max-seconds-to-wait* 10 "Max seconds to wait for all replies to come in")
(defparameter *direct-reply-max-seconds-to-wait* *max-seconds-to-wait* "Max seconds to wait for direct replies")
;(defparameter *direct-reply-max-seconds-to-wait* 100 "Max seconds to wait for direct replies")
(defvar *incoming-mailbox* (mpcompat:make-mailbox) "Destination for incoming objects off the wire. Should be an actor in general. Mailbox is only for testing.")
(defparameter *max-buffer-length* 65500)
(defvar *hmac-keypair* nil "Keypair for this running instance. Should only be written to by *hmac-keypair-actor*")
(defvar *hmac-keypair-lock* (mpcompat:make-lock) "Lock for *hmac-keypair*")
(defvar *hmac-keypair-actor* nil "Actor managing *hmac-keypair*")

; TODO: Document what uber-network and uber-set mean. See note H.

(defparameter *eripa* nil "Externally-routable IP address (or domain name) for this machine, if known")

(defvar *last-uid* 0 "Simple counter for making UIDs. Only used for :short style UIDs.")
(defvar *last-tiny-uid* 0 "Simple counter for making UIDs")

(defparameter *delay-interim-replies* t "True to delay interim replies.
  Should be true, especially on larger networks. Reduces unnecessary interim-replies while still ensuring
  some partial information is propagating in case of node failures.")

;;;; DEPRECATE
(defparameter *use-all-neighbors* 2 "True to broadcast to all neighbors; nil for none (no forwarding).
                                       Can be an integer to pick up to n neighbors.")
;;;; DEPRECATE
(defparameter *active-ignores* t "True to reply to sender when we're ignoring a message from that sender.")

(defparameter *max-server-tries* 4 "How many times we can try finding an unused local server port before we give up. 1 to only try once.")

; Actuals below can differ from nominal if you're running multiple servers on the same machine in different processes.
(defvar *actual-udp-gossip-port* nil "Local gossip UDP network port actually in use")
(defvar *actual-tcp-gossip-port* nil "Local gossip TCP network port actually in use")
(defvar *udp-gossip-socket* nil "Local passive UDP gossip socket, if any")
(defvar *tcp-gossip-socket* nil "Local passive TCP gossip socket, if any")

(defparameter *max-server-tries* 4 "How many times we can try finding an unused local server port before we give up. 1 to only try once.")
(defparameter *shutting-down*     nil "True to shut down gossip-server")
(defparameter *shutdown-msg* (make-array 8 :element-type '(UNSIGNED-BYTE 8) :initial-contents #(115 104 117 116 100 111 119 110)) "shutdown")
(defun shutdown-msg-len () (length *shutdown-msg*))

(defvar *tcp-gossip-server-name* "TCP Gossip Server")
(defvar *udp-gossip-server-name* "UDP Gossip Server")

(defvar *transport* nil "Network transport endpoint.")

(defvar *ll-application-handler* nil "Set to a function to be called when the API methods reach their target.")

(defun get-node (pkey-id)
  "return the cosi-simgen:node for a pkey"
  (gossip::lookup-node pkey-id))

;; ------------------------------------------------------------------------------
;; Generic handling for expected authenticated messages. Check for
;; valid deserialization, check deserialization is a
;; pbc:signed-message, check for valid signature, then call user's
;; handler with embedded authenticated message. If any failure along
;; the way, just drop the message on the floor.

(defun do-process-authenticated-packet (deserialize-fn body-fn)
  "Handle decoding and authentication. If fails in either case just do nothing."
  (let ((decoded (handler-case
                   ;; might not be a valid serialization
                   (funcall deserialize-fn)
                   (error (e) (edebug 1 :error "Invalid deserialization" e)
                          nil))))
    (when (and decoded
               (handler-case
                   ;; might not be a pbc:signed-message
                   (pbc:check-message decoded)
                 (error (e) (edebug 1 :error "Invalid signature" e)
                        nil)))
      (funcall body-fn (pbc:signed-message-msg decoded)))))

(defmacro with-authenticated-packet ((packet-arg) deserializer &body body)
  "Macro to simplify decoding and authentication"
  `(do-process-authenticated-packet (lambda ()
                                      ,deserializer)
                                    (lambda (,packet-arg)
                                      ,@body)))

(defun remove-keywords (arg-list keywords)
  (let ((clean-tail arg-list))
    ;; First, determine a tail in which there are no keywords to be removed.
    (loop for arg-tail on arg-list by #'cddr
	  for (key) = arg-tail
	  do (when (member key keywords :test #'eq)
	       (setq clean-tail (cddr arg-tail))))
    ;; Cons up the new arg list until we hit the clean-tail, then nconc that on
    ;; the end.
    (loop for arg-tail on arg-list by #'cddr
	  for (key value) = arg-tail
	  if (eq arg-tail clean-tail)
	    nconc clean-tail
	    and do (loop-finish)
	  else if (not (member key keywords :test #'eq))
	    nconc (list key value)
	  end)))

(defmacro with-keywords-removed ((var keywords &optional (new-var var))
				 &body body)
  "binds NEW-VAR (defaults to VAR) to VAR with the keyword arguments specified
in KEYWORDS removed."
  `(let ((,new-var (remove-keywords ,var ',keywords)))
     ,@body))

; Typical cases:
; Case 1: *use-all-neighbors* = true and *active-ignores* = nil. The total-coverage (neighborcast) case.
; Case 2: *use-all-neighbors* = 1 and *active-ignores* = true. The more common gossip case.
; Case 3: *use-all-neighbors* = true and *active-ignores* = true. More messages than necessary. NOW A FORBIDDEN CASE.
; Case 4: *use-all-neighbors* = 1 and *active-ignores* = false. Lots of timeouts. Poor results. NOW A FORBIDDEN CASE.

;;; DEPRECATE. Use forward-to slot on messages for this now.
(defun set-protocol-style (kind &optional (n 2))
  "Set style of protocol.
   :gossip style to pick one neighbor at random to send solicitations to.
      There's no guarantee this will reach all nodes. But it's quicker and more realistic.
   :neighborcast   style to send solicitations to all neighbors. More likely to reach all nodes but replies may be slower.
   Neither style should result in timeouts of a node waiting forever for a response from a neighbor."
  (case kind
    (:gossip (setf *use-all-neighbors* n
                   *active-ignores* t))  ; must be true when *use-all-neighbors* is nil. Otherwise there will be timeouts.
    (:neighborcast  (setf *use-all-neighbors* t
                   *active-ignores* nil)))
  kind)

(defun get-protocol-style ()
  "Get style of protocol. See set-protocol-style."
  (cond ((and (null *use-all-neighbors*)
              *active-ignores*)
         :noforward) ; use 0 neighbors means "no forward" which is generally counterproductive except during bootstrapping
        ((and (integerp *use-all-neighbors*)
              *active-ignores*)
         (if (zerop *use-all-neighbors*)
             (values :noforward)
             (values :gossip *use-all-neighbors*)))
        ((and (eql t *use-all-neighbors*)
              (null *active-ignores*))
         :neighborcast)
        (t :unknown)))
             
; (set-protocol-style :neighborcast) ; you should expect 100% correct responses most of the time in this mode
; (set-protocol-style :gossip)       ; you should expect 100% correct responses very rarely in this mode

#|
Discussion: :gossip style is more realistic for "loose" networks where nodes don't know much about their neighbors.
:neighborcast style is better after :gossip style has been used to discover the graph topology and agreements about collaboration
are in place between nodes.
|#

(defun make-uid-mapper ()
  "Returns a table that maps UIDs to objects"
  (kvs:make-store ':hashtable :test 'equalp))

;;; defglobal here makes running tests easier
#+LISPWORKS
(hcl:defglobal-variable *nodes* (make-uid-mapper) "Table for mapping node UIDs to nodes known by local machine")
#+OpenMCL
(ccl:defglobal *nodes* (make-uid-mapper) "Table for mapping node UIDs to nodes known by local machine")

(defun clear-local-nodes ()
  "Delete all knowledge of local real and proxy nodes. Usually used only for testing and startup."
   (kvs:clear-store *nodes*))

(defun local-nodes-matching (pred)
  "Returns a list of local nodes for which pred returns true. If pred=T, return all local nodes."
  (when pred
    (loop for node being each hash-value of *nodes*
      when (or (eql t pred)
               (ignore-errors (funcall pred node)))
      collect node)))

(defun real-node-p (node)
  (and (typep node 'gossip-node)
       (not (temporary-p node))))

(defun proxy-node-p (node)
  "Returns true if node is a non-temporary proxy node"
  (and (typep node 'proxy-gossip-node)
       (not (temporary-p node))))

(defun local-real-nodes ()
  "Returns a list of nodes that are real (non-proxy), permanent and resident on this machine."
  (local-nodes-matching 'real-node-p))

(defun proxy-to-host (&rest hostpair)
  "Returns a proxy (could be temporary, and it fact probably will be) with real-uid=0 pointing to given ipaddr and port"
  (let ((proxies (local-nodes-matching (lambda (node) (and (typep node 'proxy-gossip-node)
                                                           (eql 0 (real-uid node)))))))
    (find-if (lambda (node)
               (node-matches-host? node hostpair))
             proxies)))

(defun inspect-temp-proxies ()
  "Only used for debugging"
  (let ((proxies (local-nodes-matching (lambda (node) (and (typep node 'proxy-gossip-node))))))
    (dolist (proxy proxies)
      (inspect proxy))))

(defun random-node ()
  "Only used for testing"
  (let ((nodes (local-real-nodes)))
    (nth (random (length nodes)) nodes)))

(defun local-real-uids ()
  "Returns a list of UIDs representing real (non-proxy) nodes resident on this machine."
  (mapcar 'uid (local-real-nodes)))

(defun remote-real-nodes ()
  "Returns a list of permanent proxies that point at remote nodes"
  (local-nodes-matching 'proxy-node-p))

(defun remote-real-uids ()
  "Returns a list of UIDs representing real nodes known to be resident on other machines."
  (mapcar 'uid (remote-real-nodes)))
(defun uber-set ()
  "Returns a complete list of UIDs of real nodes known on both this machine and other machines.
  Note that some members of the list may point to [permanent] proxies on this machine."
  (mapcar 'uid (local-nodes-matching (lambda (node)
                                       (and (typep node 'abstract-gossip-node)
                                            (not (temporary-p node)))))))
  
(defun aws-p ()
  "Returns true if we're running on an AWS EC2 instance.
   Always runs quickly."
  ; https://serverfault.com/questions/462903/how-to-know-if-a-machine-is-an-ec2-instance
  (and (probe-file "/sys/hypervisor/uuid")
       (with-open-file (s "/sys/hypervisor/uuid")
         (let ((line (read-line s nil nil nil)))
           (and line
                (> (length line) 3)
                (equalp "ec2" (subseq line 0 3)))))))

;;; HOST-TO-HBO: map HOST to an HBO (host integer in network byte order) if
;;; posible, otherwise nil.  This differs from usocket:host-to-hbo in that it
;;; returns nil when it cannot resolve HOST rather than signal an error. Also,
;;; it tries to bypass hosts that happen to have ipv6 representations, whereas
;;; usocket would signal an error, at least on LispWorks. (There's current a bug
;;; report for that problem.)

;;; HOST-TO-VECTOR-QUAD: map HOST to a vector quad if possible, otherwise
;;; nil. This differs from usocket:host-to-vector in that it does not choose a
;;; random host to map from its name to the quad in the case of multiple quads
;;; per names; instead it always chooses the first. It also differs from the
;;; LispWorks implementation in always choosing a non-ipv6 quad, whereas on
;;; LispWorks it could choose an ipv6 "quad", by virtue of its choosing a
;;; "random" host, which did not really make any sense.

(defun host-to-hbo (host)
  (let ((vector-quad?
          (host-to-vector-quad host)))
    (and vector-quad?
         (usocket::host-to-hbo vector-quad?))))

(defun host-to-vector-quad (host)
  (cond
    ((stringp host)
     ;; usocket ipv6 bug workaround starts here:
     (let ((ip (and (usocket::ip-address-string-p host)
                    (usocket:dotted-quad-to-vector-quad host))))
       (if (and ip (= 4 (length ip)))
           ;; valid IP dotted quad?
           ip
           (loop for host 
                   in (usocket::get-hosts-by-name host)
                 ;; return first non-ipv6 (16-long vector) host
                 when (not (and (typep host 'array)
                                (= (length host) 16)

                                ;; If it's possible to get a string here, don't
                                ;; get confused by that.
                                (not (stringp host))))
                   return host))))
    (t (usocket::host-to-vector-quad host))))

;; Host-to-vector-quad and host-to-hbo are not quite plug replacements for their
;; usocket replacements, which did weird things and sometimes signaled an
;; error. They are not really exported either. Kind of a mess. -mhd, 7/4/18

(defun eripa-via-network-lookup ()
  "Returns ERIPA for current process via http lookup at external site"
  (let ((dq (with-output-to-string (s)
              (cond ((aws-p)
                     (http-fetch "http://169.254.169.254/latest/meta-data/public-ipv4" s))
                    (t (http-fetch "http://api.ipify.org/" s))))))
    (when (and (stringp dq)
               (> (length dq) 0))
      (values (host-to-vector-quad dq)
              dq))))

(defun externally-routable-ip-address ()
  "Returns ERIPA for current process"
  ; add mechanisms to get this from command-line args or environment variables which should take precedence
  ;   over network lookup
  (eripa-via-network-lookup))

(defun eripa ()
  "Return externally-routable ip address of this machine. This is the primary user function.
  Caches result for quick repeated use."
  (or *eripa*
      (setf *eripa* (externally-routable-ip-address))))

(defun encode-uid (machine-id process-id numeric-id)
  (logior (ash machine-id 48)
          (ash process-id 32)
          numeric-id))

(defun generate-new-monotonic-id ()
  (mpcompat:atomic-incf *last-uid*))

#+LISPWORKS
(progn
  (fli:define-c-typedef pid_t :int)
  (fli:define-foreign-function getpid ()
    :result-type pid_t))

; Somewhat shorter than the longer uuid version, (80 bits vs. 128) and more useful for simulating with
;   two processes on the same machine because it uses PID as part of the ID. Should still work
;   fine even in real (not simulated) systems.
(defun short-uid ()
  (encode-uid (logand #xFFFFFFFF (host-to-hbo (eripa))) ; 32 bits
              (logand #xFFFF #+OPENMCL (ccl::getpid) #+LISPWORKS (getpid)) ; 16 bits
              (logand #xFFFFFFFF (generate-new-monotonic-id)))) ; 32 bits

(defun long-uid ()
  (uuid::uuid-to-integer (uuid::make-v1-uuid)))

(defun new-tiny-uid ()
  (mpcompat:atomic-incf *last-tiny-uid*))

(defun new-uid (&optional (style *default-uid-style*))
  "Generate a new UID of the given style"
  (vec-repr:bev
   (case style
     (:long  (long-uid))
     (:short (short-uid))
     (:tiny  (new-tiny-uid)))))
                   
(defun uid? (thing)
  (or (typep thing 'vec-repr:ub8v)
      (typep thing 'pbc:public-key)))

(defun uid= (thing1 thing2)
  (handler-case (vec-repr:vec= thing1 thing2)
    ; Because sometimes these things are symbols if they name actors
    (error () (equalp thing1 thing2))))

(defclass uid-slot ()
  ((uid :initarg :uid :initform (new-uid) :reader uid
        :documentation "Unique ID. These are assumed to be BEV objects.")))

(defmethod print-object ((thing uid-slot) stream)
   (with-slots (uid) thing
       (print-unreadable-object (thing stream :type t :identity nil)
          (when uid
              (prin1 (vec-repr:bev-vec uid) stream)))))

;;; Should move these to mpcompat
(defun all-processes ()
  #+Allegro   mp:*all-processes*
  #+LispWorks (mp:list-all-processes)
  #+OpenMCL   (ccl:all-processes)
  #-(or Allegro LispWorks CCL)
  (warn "No implementation of ALL-PROCESSES for this system.")
  )

(defun process-name (process)
  #+Allegro                (mp:process-name process)
  #+LispWorks              (mp:process-name process)
  #+OpenMCL                (ccl:process-name process)
  #-(or Allegro LispWorks CCL)
  (warn "No implementation of PROCESS-NAME for this system."))

(defun process-kill (process)
  #+Allegro                (mp:process-kill process)
  #+LispWorks              (mp:process-terminate process)
  #+OpenMCL                (ccl:process-kill process)
  #-(or Allegro LispWorks CCL)
  (warn "No implementation of PROCESS-KILL for this system."))

(defun stream-eofp (stream)
  "Returns true if stream is at EOF"
  #+OPENMCL
  (handler-case (ccl:stream-eofp stream) ; could be a bad-fd error if other end got closed
    (error () t))
  #+LISPWORKS
  (stream:stream-check-eof-no-hang stream))

(defun find-process (name)
  "Returns a process with given name, if any."
  (find-if (lambda (process) (ignore-errors (string-equal name (subseq (process-name process) 0 (length name))))) (all-processes)))

(defclass gossip-message-mixin (uid-slot)
  ((timestamp :initarg :timestamp :initform (usec::get-universal-time-usec) :accessor timestamp
              :documentation "Timestamp of message origination")
   (hopcount :initarg :hopcount :initform 0 :accessor hopcount
             :documentation "Number of hops this message has traversed.")
   (kind :initarg :kind :initform nil :accessor kind
         :documentation "The verb of the message, indicating what action to take.")
   (args :initarg :args :initform nil :accessor args
         :documentation "Payload of the message. Arguments to kind.")
   ))

(defgeneric copy-message (msg)
  (:documentation "Copies a message object verbatim. Mainly for simulation mode
          where messages are shared, in which case in order to increase hopcount,
          the message needs to be copied."))

(defmethod copy-message ((msg gossip-message-mixin))
  (let ((new-msg (make-instance (class-of msg)
                   :uid (uid msg)
                   :timestamp (timestamp msg)
                   :hopcount (hopcount msg)
                   :kind (kind msg)
                   :args (args msg))))
    new-msg))

(defclass solicitation (gossip-message-mixin)
  ((forward-to :initarg :forward-to :initform *use-all-neighbors* :accessor forward-to
             :documentation "Normally true, which means this solicitation should be forwarded to neighbors
             of the one that originally received it. If nil, it means never forward. In that case, if a reply is expected,
             just reply immediately.
             It can be an integer n, which means to forward to up to n random neighbors. (This is traditional
             gossip protocol.)
             It can also simply be T, which means to forward to all neighbors. (This is neighborcast protocol.)")
   (reply-to :initarg :reply-to :initform nil :accessor reply-to
             :documentation "Nil for no reply expected. :UPSTREAM or :GOSSIP or :NEIGHBORCAST indicate
             replies should happen by one of those mechanisms, or a UID to request a direct reply to
             a specific node.")
   (graphid :initarg :graphid :initform +default-graphid+ :accessor graphid
            :documentation "Which graph should this message propagate through? Since nodes can be part of multiple
             graphs, which identifies which set of neighbors to use when forwarding the message. +default-graphid+ will be the default ground
             graph which can be considered a 'physical' graph, while the rest are 'logical' but this is just a convention."))
  (:documentation "An initial message sent to a gossip network or gossip node. Some solicitations require replies;
    some don't."))

(defun make-solicitation (&rest args)
  (apply 'make-instance 'solicitation args))

(defmethod neighborcast? ((msg solicitation))
  "True if message is requesting neighborcast protocol"
  (eql t (forward-to msg)))

(defmethod copy-message :around ((msg solicitation))
  (let ((new-msg (call-next-method)))
    (setf (forward-to new-msg) (forward-to msg)
          (reply-to new-msg) (reply-to msg)
          (graphID new-msg)  (graphID msg))
    new-msg))

(defclass solicitation-uid-slot ()
  ((solicitation-uid :initarg :solicitation-uid :initform nil :accessor solicitation-uid
                     :documentation "UID of solicitation message that elicited this reply.")))

; Note: If you change a message before forwarding it, you need to create a new
;   message with a new UID. (Replies can often be changed as they percolate backwards;
;   they need new UIDs so that a node that has seen one set of information won't
;   automatically ignore it.)
(defclass reply (gossip-message-mixin solicitation-uid-slot)
  ()
  (:documentation "Reply message. Used to reply to solicitations that need an :UPSTREAM or direct reply.
     This class is not used for :GOSSIP or :NEIGHBORCAST replies; those replies are just new solicitations.
     Why? Because only :UPSTREAM replies require the coalescence (i.e. reduce) mechanism and
     for those, an expectation needs to be set up in the sending node that a reply will be coming back,
     and a teardown mechanism happens when all expected replies have come back or a timeout occurs.
     No coalescence, expectation, or teardown needs to happen for :GOSSIP or :NEIGHBORCAST replies.

     Direct replies do establish expectations, so they use the reply class. Direct replies also use coalescence
     but only at the ultimate receiver node since there are no other nodes where coalescence could occur.

     It is common and expected to receive multiple :UPSTREAM or direct replies matching a given solicitation-uid.
     :UPSTREAM replies are 'inverse broadcasts' in that they have many sources that funnel
     back to one ultimate receiver -- the originator of the solicitation.
     Direct replies can be similar except the message is sent directly from the ultimate recipient back
     to the ultimate sender without being forwarded through the network."))

(defclass interim-reply (reply)
  ()
  (:documentation "Interim replies engender a forwarded interim reply immediately to coalesce
    all available data. A later interim reply (or a final reply) from node X for solicitation Y will override
    an earlier interim reply. 'Later' here means the reply itself has a UID that's larger than the 'older'
    one."))

(defun make-interim-reply (&rest args)
  (apply 'make-instance 'interim-reply args))

(defclass final-reply (reply)
  ()
  (:documentation "Final replies engender a forwarded final reply from node X iff all other replies node X
    is expecting have also been received and are final replies. Furthermore, all reply-expectation structures
    must be cleaned up in this event.
    Otherwise a final reply to node X just engenders another interim reply upstream from node X."))

(defun make-final-reply (&rest args)
  (apply 'make-instance 'final-reply args))

(defclass system-async (gossip-message-mixin solicitation-uid-slot)
  ()
  (:documentation "Used only for special timeout and socket-wakeup messages. In this case, solicitation-uid field
    is used to indicate which solicitation should be timed out at the receiver of this message."))

(defun make-system-async (&rest args)
  (let ((msg (apply 'make-instance 'system-async args)))
    (when (and (eql :timeout (kind msg))
               (null (solicitation-uid msg)))
      (error "No solicitation-uid on timeout"))
    msg))

(defmethod copy-message :around ((msg reply))
  (let ((new-msg (call-next-method)))
    (setf (solicitation-uid new-msg) (solicitation-uid msg))
    new-msg))

(defmethod copy-message :around ((msg system-async))
  (let ((new-msg (call-next-method)))
    (setf (solicitation-uid new-msg) (solicitation-uid msg))
    new-msg))

(defclass abstract-gossip-node (uid-slot)
  ((logfn :initarg :logfn :initform 'default-logging-function :accessor logfn
          :documentation "If non-nil, assumed to be a function called with every
              message seen to log it.")
   (temporary-p :initarg :temporary-p :initform nil :accessor temporary-p
                :documentation "True if this node should be considered temporary, i.e. should not be
           found by many functions that look for node in the local node table. (Eventually, temporary
           nodes should be stored in a separate, weak hash table.)")))

(defclass gossip-actor (ac:actor)
  ((node :initarg :node :initform nil :accessor node
         :documentation "The gossip-node on behalf of which this actor works")))

(defclass actor-mixin ()
  ((actor :initarg :actor :initform nil :accessor actor
          :documentation "Actor for this node")))

(defclass gossip-node (abstract-gossip-node actor-mixin)
  ((message-cache :initarg :message-cache :initform (make-uid-mapper) :accessor message-cache
                  :documentation "Cache of seen messages. Table mapping UID of message to UID of upstream sender.
          Used to ensure identical messages are not acted on twice, and to determine where
          replies to a message should be sent in case of :UPSTREAM messages.")
   (repliers-expected :initarg :repliers-expected :initform (kvs:make-store ':hashtable :test 'equalp)
                      :accessor repliers-expected
                      :documentation "2-level Hash-table mapping a solicitation id to another hashtable of srcuids
          that I expect to reply to that solicitation. Values in second hashtable are either interim replies
          that have been received from that srcuid for the given solicitation id.
          Only accessed from this node's actor thread. No locking needed.
          See Note B below for more info.")
   (reply-cache :initarg :reply-cache :initform (kvs:make-store ':hashtable :test 'equalp)
                :accessor reply-cache
                :documentation "Hash-table mapping a solicitation id to some data applicable to THIS node
          for that solicitation. Only accessed from this node's actor
          thread. No locking needed. Only used for duration of a solicitation/reply cycle.")
   (local-kvs :initarg :local-kvs :initform (kvs:make-store ':hashtable :test 'equal) :accessor local-kvs
              :documentation "Local persistent key/value store for this node. Put long-lived global state data here.")
   (neighbors :initarg :neighbors :initform (kvs:make-store ':hashtable :test 'equal) :accessor neighbors
              :documentation "Table of lists of UIDs of direct neighbors of this node. This is the mechanism that establishes
              the connectivity of the node graph. Table is indexed by graphID.")
   (timers :initarg :timers :initform (kvs:make-store ':hashtable :test 'equalp) :accessor timers
           :documentation "Table mapping solicitation uids to a timer dealing with replies to that uid.")
   (timeout-handlers :initarg :timeout-handlers :initform (kvs:make-store ':hashtable :test 'equalp) :accessor timeout-handlers
                     :documentation "Table of functions of 1 arg: timed-out-p that should be
           called to clean up after waiting operations are done. Keyed on solicitation id.
           Timed-out-p is true if a timeout happened. If nil, it means operations completed without
           timing out.")))

(defmethod clear-caches ((node gossip-node))
  "Caches should be cleared in the normal course of events, but this can be used to make sure."
  (kvs:clear-store! (message-cache node))
  (kvs:clear-store! (repliers-expected node))
  (kvs:clear-store! (reply-cache node))
  ; don't clear the local-kvs. That should be persistent.
  )

; We'll use these for real (not simulated on one machine) protocol over the network
(defclass proxy-gossip-node (abstract-gossip-node actor-mixin)
  ((real-address :initarg :real-address :initform nil :accessor real-address
            :documentation "Real IP or DNS address of remote node")
   (real-port :initarg :real-port
              :initform (emotiq/config:setting :gossip-server-port)
              :accessor real-port
              :documentation "Real port of remote node")
   (real-uid :initarg :real-uid :initform nil :accessor real-uid
                  :documentation "UID of the (real) gossip node on the other end.
               This proxy node will also have its own UID just for local lookup purposes,
               but the real-uid is used to route it to the proper node on the remote
               machine."))
  (:documentation "A local [to this process] standin for a real gossip-node located elsewhere.
              All we know about it is its UID and address, which is enough to transmit a message to it.
              Proxy nodes never have neighbors."))

(defmethod print-object ((thing proxy-gossip-node) stream)
   (with-slots (real-address) thing
       (print-unreadable-object (thing stream :type t :identity nil)
          (when real-address (princ (usocket::host-to-hostname real-address) stream)))))

(defmethod clear-caches ((node proxy-gossip-node))
  "Caches should be cleared in the normal course of events, but this can be used to make sure."
  )

(defclass tcp-gossip-node (proxy-gossip-node)
  ())

(defclass udp-gossip-node (proxy-gossip-node)
  ())

(defclass no-targets (error)
  ((current-host :initarg :current-host :initform nil :accessor current-host)
   (message :initarg :message :initform nil :accessor message
            :documentation "Solicitation attempting to be delivered"))
  (:documentation "Error condition indicating no targets are available at a host with an anonymous destination."))

(defclass no-reply-destination (error)
  ((reply :initarg :reply :initform nil :accessor reply)
   (soluid :initarg :soluid :initform nil :accessor soluid)
   (data :initarg :data :initform nil :accessor data))
  (:documentation "No destination for reply"))

(defmacro as-uid (thing)
  "If thing has a UID, retrieve it. Otherwise assume it's already a UID."
  `(if (typep ,thing 'uid-slot)
       (uid ,thing)
       ,thing))

(defmethod node-matches-host? ((node proxy-gossip-node) (hostpair cons))
  "Returns true if host of node matches hostpair."
  (with-slots (real-address real-port) node
    (and (usocket::ip= real-address (first hostpair))
         (= real-port (second hostpair)))))

(defmethod node-matches-host? (node host)
  (declare (ignore node host))
  nil)

(defun node-in-hosts (node &optional (hosts *hosts*))
  "Returns true if node is a proxy node that is represented in hosts,
  where each host is a pair of (ipaddr port)."
  (when (proxy-node-p node)
    (member-if (lambda (hostpair)
                 (node-matches-host? node hostpair))
               hosts)))

(defun host-in-nodes (hostpair &optional (nodes (remote-real-nodes)))
  "Returns a list of members of *hosts* that are not represented in (remote-real-nodes)."
  (member-if (lambda (node)
               (node-matches-host? node hostpair))
             nodes))

(defun new-nodes (&optional (hosts *hosts*))
  "Returns a list of members of (remote-real-nodes) whose hosts are not represented in *hosts*.
   Such nodes are not errors; they merely represent nodes that said hello to us whose hosts were
   not in our hosts.conf file."
  (let ((nodes (remote-real-nodes)))
    (remove-if (lambda (node)
                 (node-in-hosts node hosts))
               nodes)))

(defun missing-hosts (&optional (hosts *hosts*))
  "Returns a list of members of *hosts* that are not [yet] represented in (remote-real-nodes).
  Such hosts are concerning; they indicate we have not yet heard from one or more hosts
  that were listed in our hosts.conf file."
  (remove-if (lambda (hostpair)
               (host-in-nodes hostpair))
             hosts))

(defmethod gossip-dispatcher (node &rest actor-msg)
  "Extracts gossip-msg from actor-msg and calls deliver-gossip-msg on it"
  (let ((gossip-cmd (first actor-msg)))
    (case gossip-cmd
      (:gossip
       (unless node (error "No node attached to this actor!"))
       (destructuring-bind (srcuid gossip-msg) (cdr actor-msg)
         (deliver-gossip-msg gossip-msg node srcuid))))))

(defmethod make-gossip-actor ((node t))
  (make-instance 'gossip-actor
    :node node
    :fn 
    (lambda (&rest msg)
      (edebug 6 "Gossip Actor" (ac::current-actor) "received" msg)
      (apply 'gossip-dispatcher node msg))))

(defun memoize-node (node)
  "Ensure this node is memoized on *nodes*"
  (kvs:relate-unique! *nodes* (vec-repr:bev-vec (uid node)) node)
  node)

(defun %make-node (&rest args)
  "Makes a new [real, non-proxy] gossip node. Doesn't memoize it."
  (let ((neighborhood (getf args :neighborhood))) ; allow to specify :neighborhood as list, for +default-graphid+
    (with-keywords-removed (args (:neighborhood))
      (let ((node (apply 'make-instance 'gossip-node args)))
        (when neighborhood
          (mapcar (lambda (uid)
                    (pushnew (vec-repr:bev uid) (neighborhood node)))
                  neighborhood))
        node))))

(defmethod initialize-node ((node gossip-node) &key pkey skey)
  (declare (ignore skey)) ; methods specialized on other types of nodes use this. We don't.
  (setf (actor node) (make-gossip-actor node))
  (when pkey ; pkey, if given, takes precedence over automatically-generated UID
    (set-uid node pkey))
  (memoize-node node))

(defmethod make-node ((kind (eql :gossip)) &rest rest &key pkey skey &allow-other-keys)
  (with-keywords-removed (rest (:pkey :skey))
    (let ((node (apply '%make-node rest)))
      (initialize-node node :pkey pkey :skey skey)
      node)))

(defmethod set-uid ((self uid-slot) value)
  (setf (slot-value self 'uid) value))

(defun make-proxy-node (mode &rest args)
  "Makes a new proxy node of given mode: :UDP or :TCP"
  (let* ((node (case mode
                 (:tcp (apply 'make-instance 'tcp-gossip-node args))
                 (:udp (apply 'make-instance 'udp-gossip-node args))))
         (actor (make-gossip-actor node)))
    (setf (actor node) actor)
    ; rule: We should never have a proxy and a real node with same uid.
    ;  Furthermore: uid of a proxy should always be forced to match its real-uid, except when its real-uid=0.
    (unless (= 0 (real-uid node))
      (let ((oldnode (lookup-node (real-uid node))))
        (when oldnode
          (edebug 1 :WARN oldnode "being replaced by proxy" node)))
      (set-uid node (real-uid node)))
    (memoize-node node)))

(defgeneric locate-local-uid-for-graph (graphID)
  (:documentation "Returns UID of some local real node that's part of given graphID, if any"))

(defmethod locate-local-uid-for-graph ((graphID (eql :UBER)))
  "Every local real node and every local permanent proxy is part of the :UBER set by definition.
   But here we only want to return a real node. No proxies allowed."
  ; This could be more efficient with proper short-circuiting. Fix it later.
  (let ((node (first (local-real-nodes))))
    (when node (uid node))))

(defmethod locate-local-uid-for-graph ((graphID t))
  ; Again, not as efficient as it should be.
  (let ((node (car (local-nodes-matching (lambda (node)
                                           (and (real-node-p node)
                                                (kvs:lookup-key (neighbors node) graphID)))))))
    (when node (uid node))))

;;;; Graph making routines. Mostly just for testing and simulation, because these only work on local machine.
(defun make-nodes (numnodes)
  (dotimes (i numnodes)
    (make-node ':gossip)))

(defun listify-nodes ()
  (local-nodes-matching t))

(defmethod neighborhood ((node gossip-node) &optional (graphID +default-graphid+))
  "If graphID = :UBER, return the uber-set rather than the neighbors table in the node.
   The uber-set is mostly for bootstrapping a gossip network."
  (if (eql :UBER graphID)
      (uber-set)
      (kvs:lookup-key (neighbors node) graphID)))

(defmethod dissolve-neighborhood ((node gossip-node) graphID)
  "Removes connections associated with given graphID. graphID _must_ be specified here.
   Returns true if graphID in fact existed on this node; nil otherwise."
  (kvs:remove-key (neighbors node) graphID))

(defmethod (setf neighborhood) (value (node gossip-node) &optional (graphID +default-graphid+))
  "For the benefit of pushnew"
  (kvs:relate-unique (neighbors node) graphid value))

(defmethod connect ((node1 gossip-node) (node2 gossip-node) &optional (graphID +default-graphid+))
  "Establish an edge between two nodes. Because every node must know its nearest neighbors,
   we store the edge information twice: Once in each endpoint node.
   This method is only for connecting local, real nodes."
  (pushnew (uid node1) (neighborhood node2 graphID))
  (pushnew (uid node2) (neighborhood node1 graphID)))
  
(defmethod connected? ((node1 gossip-node) (node2 gossip-node) &optional (graphID +default-graphid+))
  (or (member (uid node2) (neighborhood node1 graphID) :test 'uid=)
      ; redundant if we connected the graph correctly in the first place
      (member (uid node1) (neighborhood node2 graphID) :test 'uid=)))

(defun linear-path (nodelist &optional (graphID +default-graphid+))
  "Create a linear path through the nodes"
  (when (second nodelist)
    (connect (first nodelist) (second nodelist) graphID)
    (linear-path (cdr nodelist) graphID)))

(defun random-connection (nodelist)
  (let* ((len (length nodelist))
         (node1 (elt nodelist (random len)))
         (node2 (elt nodelist (random len))))
    (if (eq node1 node2)
        (random-connection nodelist)
        (values node1 node2))))

(defun random-new-connection (nodelist graphID)
  (multiple-value-bind (node1 node2) (random-connection nodelist)
    (if (connected? node1 node2 graphID)
        (random-new-connection nodelist graphID)
        (values node1 node2))))

(defun add-random-connections (nodelist n graphID)
  "Adds n random edges between pairs in nodelist, where no connection currently exists."
  (dotimes (i n)
    (multiple-value-bind (node1 node2) (random-new-connection nodelist graphID)
      (connect node1 node2 graphID))))

(defun make-graph (numnodes &key (fraction 0.5) (graphID +default-graphid+))
  "Build a graph with numnodes nodes. Strategy here is to first connect all the nodes in a single
   non-cyclic linear path, then add f*n random edges, where n is the number of nodes.
   If graphID is not = +default-graphid+, a new graph will be created out of existing nodes
   in addition to any existing graph(s) and numnodes will be ignored."
  (when (eql graphID +default-graphid+)
    (clear-local-nodes)
    (make-nodes numnodes))
  (let ((nodelist (local-real-nodes)))
    ; following guarantees a single connected graph
    (linear-path nodelist graphID)
    ; following --probably-- makes the graph an expander but we'll not try to guarantee that for now
    (add-random-connections nodelist (round (* fraction (length nodelist))) graphID))
  numnodes)

; Demonstrate two graphs existing simultaneously with only one set of nodes.
; (make-graph 10)
; (make-graph 0 :graphid ':foo)
; (visualize-nodes)
; (visualize-nodes ':foo)
; (visualize-nodes ':uber) ; this one is always fully-connected. Always represents the pseudo-graph of all known nodes.

;;;; Graph saving/restoring routines

(defun as-hash-table (test alist)
  "Builds a hash table from an alist"
  (let ((ht (make-hash-table :test test)))
    (dolist (pair alist)
      (setf (gethash (car pair) ht) (cdr pair)))
    ht))

(defmethod readable-value ((me t))
  (let ((*package* (find-package :gossip)))
    (format nil "~S" me)))

(defmethod readable-value ((me symbol))
  (let ((*package* (find-package :gossip)))
    (format nil "'~S" me)))

(defmethod alistify-hashtable ((table hash-table))
   (loop for key being each hash-key of table using (hash-value val) collect (cons key val)))

(defmethod readable-value ((me hash-table))
  (with-output-to-string (s)
    (format s "(as-hash-table~%")
    (format s "~T~T~A~%" (readable-value (hash-table-test me)))
    (format s "~T~T~A)~%" (readable-value (alistify-hashtable me)))))

(defmethod readable-value ((me list))
  (let ((*package* (find-package :gossip)))
    (format nil "'~S" me)))

(defmethod save-node ((node gossip-node) stream)
  "Write a form to stream that will reconstruct given node"
  (let ((*package* (find-package :gossip)))
    (flet ((write-slot (initarg value) ; assumes accessors and initargs are named the same
             (format stream "~%  ~S ~A" initarg (readable-value value))))
      (format stream "(make-node ':gossip")
      (write-slot :uid (uid node))
      (write-slot :neighbors (neighbors node))
      (write-slot :logfn (logfn node))
      (write-slot :local-kvs (local-kvs node))
      (format stream "~T)~%"))))

(defun save-graph (stream)
  (format stream "(in-package :gossip)~%~%")
  (mapc (lambda (node) (save-node node stream)) (local-real-nodes)))

(defun save-graph-to-file (pathname)
  "Save current graph to file. Restore by calling restore-graph-from-file.
   Makes experimentation easier."
  (with-open-file (stream pathname :direction :output)
    (format stream ";;; ~A~%" (file-namestring pathname))
    (format stream ";;; Saved graph file.~%")
    (format stream ";;; Call gossip::restore-graph-from-file on this file to restore graph from it.~%~%")
    (save-graph stream))
  pathname)

(defun restore-graph-from-file (pathname)
  "Restores a graph from a file saved by save-graph-to-file."
  (clear-local-nodes)
  (load pathname))

;;;; End of Graph saving/restoring routines

#|
To send a message that doesn't require a reply:
Use #'solicit.
To send a message that does require a reply:
Use #'solicit-wait.

To send a message that you want a direct response to:
Use #'solicit-direct and make your message manually with the :reply-to slot being the UID of the node that should expect all replies.

To send a message from a NODE that the node wants a direct response to:
The node should make the message manually with the :reply-to slot being the UID of the node itself.
The node should call (send-msg msg uid #'final-continuation), where uid is the UID of the node itself [yes, you send
the message to yourself] and final-continuation is a single-argument function of a reply, where that reply is the coalesced reply
the node itself would send upstream if it were an :UPSTREAM message. If final-continuation is nil, that reply just gets
dropped on the floor.
|#

(defun actor-send (&rest args)
  "Error-safe version of ac:send. Returns nil if successful; otherwise returns error object"
  (gossip-handler-case (progn (apply 'ac:send args)
                         nil)
                       (error (e) e)))

;; NOTE: "direct" here refers to the mode of reply, not the mode of sending.
(defun solicit-direct (node kind &rest args)
  "Like solicit-wait but asks for all replies to be sent back to node directly, rather than percolated upstream.
  Don't use this on messages that don't expect a reply, because it'll wait forever."
  (unless node
    (error "No destination node supplied. You might need to run make-graph or restore-graph-from-file first."))
  (let* ((uid (as-uid node))
         (mbox (mpcompat:make-mailbox))
         (actor (ac:make-actor (lambda (&rest msg) (apply 'actor-send mbox msg))))
         (actor-name (gentemp "OUTPUTTER" :gossip)))
    (unwind-protect
        (progn 
          (ac:register-actor actor actor-name)
          (let* ((solicitation (make-solicitation
                                :reply-to uid
                                :kind kind
                                :forward-to t ; neighborcast
                                :args args))
                 (soluid (uid solicitation)))
            (send-msg solicitation
                      uid                   ; destination
                      actor-name)
            (multiple-value-bind (response success) (mpcompat:mailbox-read mbox (* 1.2 *direct-reply-max-seconds-to-wait*))
              ; gotta wait a little longer than *direct-reply-max-seconds-to-wait* because that's how long the actor timeout will take.
              ;   Only after that elapses, will an actor put the value into the mbox.
              (values 
               (if success
                   (first (args (first response))) ; should be a FINAL-REPLY
                   (except :name :TIMEOUT))
               soluid))))
      (ac:unregister-actor actor-name))))

(defun solicit (node kind &rest args)
  "Send a solicitation to the network starting with given node. This is the primary interface to 
  the network to start an action from the outside. Nodes shouldn't use this function to initiate an
  action because they should set the srcuid parameter to be their own rather than nil."
  (unless node
    (error "No destination node supplied. You might need to run make-graph or restore-graph-from-file first."))
  (let ((uid (as-uid node)))
    (let* ((solicitation (make-solicitation
                          :kind kind
                          :args args))
           (soluid (uid solicitation)))
      (send-msg solicitation
                uid      ; destination
                nil)     ; srcuid
      soluid)))

(defun solicit-wait (node kind &rest args)
  "Like solicit but waits for a reply. Only works for :UPSTREAM replies.
  Don't use this on messages that don't expect a reply, because it'll wait forever."
  (unless node
    (error "No destination node supplied. You might need to run make-graph or restore-graph-from-file first."))
  (let* ((uid (as-uid node))
         (mbox (mpcompat:make-mailbox))
         (actor (ac:make-actor (lambda (&rest msg) (apply 'actor-send mbox msg))))
         (actor-name (gentemp "OUTPUTTER" :gossip)))
    (unwind-protect
        (progn
          (ac:register-actor actor actor-name)
          (let* ((solicitation (make-solicitation
                                :reply-to :UPSTREAM
                                :kind kind
                                :args args))
                 (soluid (uid solicitation)))
            (send-msg solicitation
                      uid      ; destination
                      actor-name)     ; srcuid
            
            (multiple-value-bind (response success) (mpcompat:mailbox-read mbox (* 1.2 *max-seconds-to-wait*))
              ; gotta wait a little longer than *max-seconds-to-wait* because that's how long the actor timeout will take.
              ;   Only after that elapses, will an actor put the value into the mbox.
              (values 
               (if success
                   (first (args (first response))) ; should be a FINAL-REPLY
                   (except :name :TIMEOUT))
               soluid))))
      (ac:unregister-actor actor-name))))

(defun solicit-progress (node kind &rest args)
  "Like solicit-wait but prints periodic progress log messages (if any)
  associated with this node to listener.
  Don't use this on messages that don't expect a reply, because it'll wait forever."
  (unless node
    (error "No destination node supplied. You might need to run make-graph or restore-graph-from-file first."))
  (let* ((uid (as-uid node))
         (node (if (typep node 'abstract-gossip-node)
                   node
                   (lookup-node node)))
         (response nil)
         (old-logger (logfn node)))
    (flet ((final-continuation (message)
             (setf response message)))
      (let* ((solicitation (make-solicitation
                            :reply-to :UPSTREAM
                            :kind kind
                            :args args))
             (soluid (uid solicitation)))
        (unwind-protect
            (progn
              (send-msg solicitation
                        uid      ; destination
                        #'final-continuation)     ; srcuid
              (let ((win (mpcompat:process-wait-with-timeout "Waiting for reply" *max-seconds-to-wait*
                                                             (lambda () response))))
                (values 
                 (if win
                     (first (args (first response)))
                     (except :name :TIMEOUT))
                 soluid)))
          (setf (logfn node) old-logger))))))

(defun multiple-list-uids (address-port-list)
  "Get a list of all UIDs of nodes at given remote address and port in
  list like ((address port) (address port) ...).
  This uses gossip and works in parallel.
  If no error, returned list will look like
  (address port uid1 uid2 ...)
  If error, returned list will look like
  (address port :ERRORMSG arg1 arg2 ...)"
  (let ((rnodes nil)
        (localnode nil)
        (allnodes nil))
    ; Make temporary proxies for the remote addresses with UID=0
    (setf rnodes (mapcar (lambda (addressport)
                           (ensure-proxy-node ':TCP (first addressport) (second addressport) 0 t))
                         address-port-list))
    (unwind-protect
        (progn
          (setf localnode (make-node ':gossip :temporary-p t))
          ; build a temporary tree with localnode as the root and send a message to it
          (mapcar (lambda (rnode)
                    (pushnew (uid rnode) (neighborhood localnode)))
                  rnodes)
          ;(format t "~%Localnode UID = ~D" (uid localnode))
          (setf allnodes (solicit-direct localnode :list-alive))
          (unless (listp allnodes) ; it's perfectly legal for solicit-xxx to return a single object rather than a list
            (setf allnodes (list allnodes)))
          ; localnode will always be one of the responders, so remove it
          (setf allnodes (remove-if
                          (lambda (ad)
                            (and (typep ad 'augmented-data)
                                 (listp (data ad))
                                 (null (cdr (data ad)))
                                 (uid= (uid localnode)
                                       (first (data ad)))))
                          allnodes)))
      (ensure-proxies allnodes) ; ensure proxies exist for all returned UIDs
      (kvs:remove-key! *nodes* (vec-repr:bev-vec (uid localnode))) ; delete temp node
      )))

;; <KLUDGE> - all uid's should be public-keys, but gossip was originally designed with knowledge of
;; the internals of public-keys

(defmethod lookup-node ((uid vec-repr:bev))
  (kvs:lookup-key *nodes* (vec-repr:bev-vec uid)))

(defmethod lookup-node ((uid pbc-interface:public-key))
  (lookup-node (pbc-interface::public-key-val uid)))

;; </KLUDGE>

(defgeneric send-msg (msg destuid srcuid)
  (:documentation "Sends msg to destuid from srcuid. Srcuid can be nil, but generally should
   contain the id of the sender, if known.
   Returns nil if successful; an error object otherwise."))

(defmethod send-msg ((msg solicitation) (destuid (eql 0)) srcuid)
  "Sending a message to destuid=0 broadcasts it to all local (non-proxy) nodes in *nodes* database.
   This is intended to be used by incoming-message-handler methods for bootstrapping messages
   before #'neighbors connectivity has been established.
   See Note D."
  (let ((nodes (local-real-uids)))
    (cond (nodes
           (let ((no-forward-msg (copy-message msg)))
             (setf (forward-to no-forward-msg) nil) ; don't let any node forward. Just reply immediately.
             (forward msg srcuid nodes)))
          (t (make-condition 'no-targets
                             :current-host (eripa)
                             :message msg)))))

(defmethod send-msg ((msg gossip-message-mixin) destuid srcuid)
  (let* ((destnode (lookup-node destuid))
         (destactor (if destnode ; if destuid doesn't represent a gossip node, assume it represents something we can actor-send to
                        (actor destnode)
                        destuid)))
    (edebug 5 "send-msg" msg srcuid "to" destuid)
    (uiop:if-let (error (actor-send destactor
                                    :gossip ; actor-verb
                                    srcuid  ; first arg of actor-msg
                                    msg))
      (progn
        (edebug 5 :warn error destuid msg :from srcuid)
        error))))

(defun current-node ()
  (uiop:if-let (actor (ac:current-actor))
    (values (node actor) actor)))

(defmethod send-self ((msg gossip-message-mixin))
  "Send a gossip message to the current node, if any.
  Should only be called from within a gossip-actor's code; otherwise nothing happens."
  (multiple-value-bind (node actor) (current-node)
    (when node ; actor will always be true too
      (actor-send actor :gossip (uid node) msg))))

;;;  TODO: Might want to also check hopcount and reject message where hopcount is too large.
;;;        Might want to not accept maybe-sir messages at all if their soluid is expired.
(defmethod accept-msg? ((msg gossip-message-mixin) (thisnode gossip-node) srcuid)
  "Returns kindsym if this message should be accepted by this node, nil and a failure-reason otherwise.
  Kindsym is the name of the gossip method that should be called to handle this message.
  Doesn't change anything in message or node."
  (declare (ignore srcuid)) ; not using this for acceptance criteria in the general method
  (let ((soluid (uid msg))
        (current-time (usec::get-universal-time-usec)))
    (cond ((> current-time (+ *max-message-age* (timestamp msg))) ; ignore too-old messages
           (values nil :too-old))
          (t
           (let ((already-seen? (kvs:lookup-key (message-cache thisnode) (vec-repr:bev-vec soluid))))
             (cond (already-seen? ; Ignore if already seen
                    (values nil :already-seen))
                   (t ; it's a new message
                    (let* ((kind (kind msg))
                           (kindsym nil))
                      (cond (kind
                             (setf kindsym (intern (symbol-name kind) :gossip))
                             (if (and kindsym (fboundp kindsym))
                                 kindsym ;; SUCCESS! We accept the message.
                                 (values nil (list :unknown-kind kindsym))))
                            (t
                             (values nil :no-kind)))))))))))

(defmethod accept-msg? ((msg reply) (thisnode gossip-node) srcuid)
  (if (eql :active-ignore (kind msg))
      (values nil :active-ignore)
      (multiple-value-bind (kindsym failure-reason) (call-next-method) ; the one on gossip-message-mixin
        ; Also ensure this reply is actually expected
        (cond (kindsym
               (let ((interim-table (kvs:lookup-key (repliers-expected thisnode) (vec-repr:bev-vec (solicitation-uid msg)))))
                 (cond (interim-table
                        (if (eql :ANONYMOUS interim-table) ; accept replies from any srcuid
                            kindsym
                            (multiple-value-bind (val present-p) (kvs:lookup-key interim-table (vec-repr:bev-vec srcuid))
                              (declare (ignore val))
                              (if present-p
                                  kindsym
                                  (values nil :unexpected-1)))))
                       (t (values nil :unexpected-2)))))
              (t (values nil failure-reason))))))

(defmethod accept-msg? ((msg system-async) (thisnode abstract-gossip-node) srcuid)
  (declare (ignore srcuid))
  ; system-asyncs are always accepted
  (intern (symbol-name (kind msg)) :gossip))

;;; TODO: Remove old entries in message-cache, eventually.
(defmethod memoize-message ((node gossip-node) (msg gossip-message-mixin) srcuid)
  "Record the fact that this node has seen this particular message.
  In cases of solicitation messages, we also care about the upstream sender, so
  we just save that as the value in the key/value pair."
  (kvs:relate-unique! (message-cache node)
                      (vec-repr:bev-vec (uid msg))
                      (or srcuid
                          t) ; because solicitations from outside might not have a srcid
                      ))

(defmethod get-upstream-source ((node gossip-node) soluid)
  "Retrieves the upstream source uid for a given soluid on this node"
  (kvs:lookup-key (message-cache node) (vec-repr:bev-vec soluid)))

(defun remove-nth (n list)
  "Returns nth item and returns item and new list."
  (let ((newlist (loop for i in list
                   for idx from 0
                   unless (= idx n)
                   collect i)))
    (values (nth n list) newlist)))
  
(defun make-random-generator (list)
  "Returns a thunk that returns another random member of list
  every time it's called. Never generates same member twice
  (unless that member appears more than once in list in the first place).
  Generates nil when no members are left."
  (lambda ()
    (when list
      (let ((n (random (length list)))
            (item nil))
        (multiple-value-setq (item list) (remove-nth n list))
        item))))

(defun use-some-neighbors (neighbors howmany)
  "Pick a few random neighbors based on value of howmany"
  (when neighbors
    (let ((len (length neighbors)))
      (cond ((integerp howmany)
             (if (< howmany 1)
                 nil ; if zero or less, return nil. Degenerate case.
                 (if (>= howmany len)
                     neighbors ; just use them all
                     (let ((fn (make-random-generator neighbors)))
                       (loop for i below howmany collect
                         (funcall fn))))))
            (howmany ; if true but not integer, just use them all
             neighbors)
            (t
             nil)))))

(defmethod get-downstream ((node gossip-node) srcuid howmany &optional (graphID +default-graphid+))
  (let ((all-neighbors (remove srcuid (neighborhood node graphID) :test 'uid=)))
    (use-some-neighbors all-neighbors howmany)))

(defun send-active-ignore (to from kind soluid failure-reason)
  "Actively send a reply message to srcuid telling it we're ignoring it."
  (let ((msg (make-interim-reply
              :solicitation-uid soluid
              :kind :active-ignore
              :args (list kind failure-reason))))
    (send-msg msg
              to
              from)))

(defun locally-dispatch-msg (kindsym node msg srcuid)
  "Final dispatcher for messages local to this machine. No validation is done here."
  (let ((logsym (typecase msg
                  (solicitation :accepted)
                  (interim-reply :interim-reply-accepted)
                  (final-reply :final-reply-accepted)
                  (t nil) ; don't log timeouts here. Too much noise.
                  )))
    (edebug (case logsym
             (:interim-reply-accepted 4)
             (:accepted 4)
             (:final-reply-accepted 4)
             (t nil))
           node logsym msg (kind msg) :from srcuid (args msg))
    (gossip-handler-case
     (funcall kindsym msg node srcuid)
     (error (c) (edebug 1 node :ERROR msg c)))))

(defmethod locally-receive-msg ((msg system-async) (node abstract-gossip-node) srcuid)
  (multiple-value-bind (kindsym failure-reason) (accept-msg? msg node srcuid)
    (cond (kindsym ; message accepted
           (locally-dispatch-msg kindsym node msg srcuid))
          (t (edebug 4 node :ignore msg :from srcuid failure-reason)))))

(defmethod locally-receive-msg ((msg gossip-message-mixin) (node gossip-node) srcuid)
  "The main dispatch function for gossip messages. Runs entirely within an actor.
  First checks to see whether this message should be accepted by the node at all, and if so,
  it calls the function named in the kind field of the message to handle it."
  (let ((soluid (uid msg)))
    (multiple-value-bind (kindsym failure-reason) (accept-msg? msg node srcuid)
      (cond (kindsym ; message accepted
             (memoize-message node msg srcuid)
             (locally-dispatch-msg kindsym node msg srcuid))
            (t ; not accepted
             (edebug 4 node :ignore msg :from srcuid failure-reason)
             (case failure-reason
               (:active-ignore ; RECEIVE an active-ignore. Whomever sent it is telling us they're ignoring us.
                ; Which means we need to ensure we're not waiting on them to reply.
                (if (typep msg 'interim-reply) ; should never be any other type
                    (destructuring-bind (kind failure-reason) (args msg)
                      (declare (ignore failure-reason)) ; should always be :already-seen, but we're not checking for now
                      (let ((was-present? (cancel-replier node kind (solicitation-uid msg) srcuid)))
                        (when (and was-present?
                                   (debug-level 4))
                          ; Don't log a :STOP-WAITING message if we were never waiting for a reply from srcuid in the first place
                          (edebug 1 node :STOP-WAITING msg srcuid))))
                    ; weird. Shouldn't ever happen.
                    (edebug 1 node :ERROR msg :from srcuid :ACTIVE-IGNORE-WRONG-TYPE)))
               (:already-seen ; potentially SEND an active ignore
                (when (typep msg 'solicitation) ; following is extremely important. See note A below.
                  ; If we're ignoring a message from node X, make sure that we are not in fact
                  ;   waiting on X either. This is essential in the case where
                  ;   *use-all-neighbors* = true and
                  ;   *active-ignores* = false [:neighborcast protocol]
                  ;   but it doesn't hurt anything in other cases.
                  (let ((was-present? (cancel-replier node (kind msg) soluid srcuid)))
                    (when (and was-present?
                               (debug-level 4))
                      ; Don't log a :STOP-WAITING message if we were never waiting for a reply from srcuid in the first place
                      (edebug 1 node :STOP-WAITING msg srcuid))
                    (unless (neighborcast? msg) ; not neighborcast means use active ignores. Neighborcast doesn't need them.
                      (send-active-ignore srcuid (uid node) (kind msg) soluid failure-reason)))))
               (t nil)))))))

(defmethod locally-receive-msg ((msg t) (thisnode proxy-gossip-node) srcuid)
  (declare (ignore srcuid))
  (error "Bug: Cannot locally-receive to a proxy node!"))

(defun forward (msg srcuid destuids)
  "Sends msg from srcuid to multiple destuids. Returns nil if successful; error otherwise."
  (setf srcuid (as-uid srcuid))

  (let ((failure (reduce (lambda (x destuid)
                           (or x (send-msg msg destuid srcuid)))
                         destuids
                         :initial-value nil)))
    failure))

(defun send-gossip-timeout-message (actor soluid)
  "Send a gossip-timeout message to an actor. (We're not using the actors' native timeout mechanisms at this time.)"
  (actor-send actor
           :gossip
           'ac::*master-timer* ; source of timeout messages is always *master-timer* thread
           (make-system-async :solicitation-uid soluid
                         :kind :timeout)))

(defun schedule-gossip-timeout (delta actor soluid)
  "Call this to schedule a timeout message to be sent to an actor after delta seconds from now.
   Keep the returned value in case you need to call ac::unschedule-timer before it officially times out."
  (when delta
    (let ((timer (ac::make-timer
                  'send-gossip-timeout-message actor soluid)))
      (ac::schedule-timer-relative timer (ceiling delta)) ; delta MUST be an integer number of seconds here
      timer)))

(defmethod make-timeout-handler ((node gossip-node) (msg solicitation) #-LISPWORKS (kind keyword) #+LISPWORKS (kind symbol))
  (let ((soluid (uid msg)))
    (lambda (timed-out-p)
      "Cleanup operations if timeout happens, or all expected replies come in. This won't hurt anything
      if no cleanup was necessary, but it's a waste of time."
      (let ((timer (kvs:lookup-key (timers node) (vec-repr:bev-vec soluid))))
        (cond (timed-out-p
               ; since timeout happened, actor infrastructure will take care of unscheduling the timeout
               (edebug 3 node :DONE-WAITING-TIMEOUT msg (more-replies-expected? node soluid t)))
              (t ; done, but didn't time out. Everything's good. So unschedule the timeout message.
               (cond (timer
                      (ac::unschedule-timer timer) ; cancel a timer prematurely, if any.
                      ; if no timer, then this is a leaf node
                      (edebug 3 node :DONE-WAITING-WIN msg))
                     (t ; note: Following log message doesn't necessarily mean anything is wrong.
                      ; If node is singly-connected to the graph, it's to be expected
                      (edebug 1 node :NO-TIMER-FOUND msg)))))
        (coalesce&reply (reply-to msg) node kind soluid)))))

(defmethod prepare-repliers ((thisnode gossip-node) soluid downstream)
  "Prepare reply tables for given node, solicitation uid, and set of downstream repliers."
  (let ((interim-table (kvs:make-store ':hashtable :test 'equalp)))
    (dolist (replier-uid downstream)
      (kvs:relate-unique! interim-table (vec-repr:bev-vec replier-uid) nil))
    (kvs:relate-unique! (repliers-expected thisnode) (vec-repr:bev-vec soluid) interim-table)
    interim-table))

;;;; GOSSIP METHODS. These handle specific gossip protocol solicitations and replies.
;;;; Except for those marked "utility function", these are strictly message handlers; they're not functions an
;;;; application programmer should call.

;;; Timeout. Generic message handler for all methods that scheduled a timeout.
;;; These never expect a reply but they can happen for methods that did expect one.
(defmethod timeout ((msg system-async) thisnode srcuid)
  "Timeouts are a special kind of message in the gossip protocol,
  and they're typically sent by a special timer thread."
  (cond ((eq srcuid 'ac::*master-timer*)
         ;;(edebug 1 thisnode :timing-out msg :from srcuid (solicitation-uid msg))
         (let* ((soluid (solicitation-uid msg))
                (timeout-handler (kvs:lookup-key (timeout-handlers thisnode) (vec-repr:bev-vec soluid))))
           (when timeout-handler
             (funcall timeout-handler t))))
        (t ; log an error and do nothing
         (edebug 1 thisnode :ERROR msg :from srcuid :INVALID-TIMEOUT-SOURCE))))

(defmethod more-replies-expected? ((node gossip-node) soluid &optional (whichones nil))
  "Utility function. Can be called by message handlers.
  If whichones is true, returns not just true but an actual list of expected repliers [or nil if none]."
  (let ((interim-table (kvs:lookup-key (repliers-expected node) (vec-repr:bev-vec soluid))))
    (when interim-table
      (if (eql :ANONYMOUS interim-table)
          nil
          (if whichones
              (loop for key being each hash-key of interim-table collect key)
              (not (zerop (hash-table-count interim-table))))))))

(defmethod maybe-sir ((msg solicitation) thisnode srcuid)
  "Maybe-send-interim-reply. The sender of this message will be thisnode itself"
  (declare (ignore srcuid))
  ; srcuid will usually (always) be that of thisnode, but we're not checking for that
  ;   because it doesn't matter if it's not true. For now.
  (let* ((soluid (first (args msg)))
         (reply-kind (second (args msg)))
         (where-to-send-reply (get-upstream-source thisnode soluid)))
    (when (more-replies-expected? thisnode soluid)
      (send-interim-reply thisnode reply-kind soluid where-to-send-reply)
      ; else we'd have already sent a final reply and no further action is needed.
      )))

;;; NO-REPLY-NECESSARY methods. One method per message.

;; Because these messages never involve a reply, even if the reply-to slot is non-nil in these messages,
;;   it will be ignored.

; Not really using this for anything, because it doesn't really do anything except traverse
(defmethod announce ((msg solicitation) thisnode srcuid)
  "Announce a message to the collective. First arg of Msg is the announcement,
   which can be any Lisp object. Recipient nodes are not expected to reply.
   This is probably only useful for debugging gossip protocols, since the only
   record of the announcement will be in the log."
  (let ((content (first (args msg))))
    (declare (ignore content))
    ; thisnode becomes new source for forwarding purposes
    (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg)))))

;;; These are the message kinds used by the high-level application programmer's gossip api.

(defgeneric lowlevel-application-handler (node)
  (:documentation "Returns something that actor-send can send to, which is associated with node.
   This is used by gossip to forward an raw gossip-message-mixin once it reaches its destination node.
   Function should accept 2 args: node and gossip-message-mixin."))

(defgeneric application-handler (node)
  (:documentation "Returns something that actor-send can send to, which is associated with node.
    This is used by gossip to forward an application message to its application destination
    once it reaches its destination node.
    Function should accept &rest application-message."))

(defmethod lowlevel-application-handler ((node abstract-gossip-node))
  "Default method"
  (or *ll-application-handler*
      (lambda (node msg)
        (edebug 1 node :LL-APPLICATION-HANDLER msg))))

(defmethod application-handler ((node abstract-gossip-node))
  "Default method"
  (lambda (&rest args)
    (apply 'edebug 1 node :APPLICATION-HANDLER args)))

(defun handoff-to-application-handlers (node msg highlevel-message-extractor)
  (let ((lowlevel-application-handler (lowlevel-application-handler node))
        (application-handler (application-handler node)))
    (when lowlevel-application-handler ; mostly for gossip's use, not the application programmer's
      (uiop:if-let (error (actor-send lowlevel-application-handler node msg))
        (if *gossip-absorb-errors*
            (edebug 1 node :ERROR error msg)
            (error error)))
      (when application-handler
        (uiop:if-let (error (apply 'actor-send application-handler (funcall highlevel-message-extractor msg)))
          (if *gossip-absorb-errors*
              (edebug 1 node :ERROR error msg)
              (error error)))))))

; I don't remember where the "k" in these names came from; I just needed a way to distinguish internal gossip
;   method names from the API functions that use them. Probably oughta just put the API functions in a different package.
(defmethod k-singlecast ((msg solicitation) thisnode srcuid)
  "Send a message to one and only one node. Application message is expected to be in (cdr args) of the solicitation.
  Destination node is expected to be in (car args) of the solicitation.
  Message will percolate along the graph until it reaches destination node, at which point it stops percolating.
  Every intermediate node will have the message forwarded through it but message will not be 'delivered' to intermediate nodes.
  Destination node is not expected to reply (at least not with builtin gossip-style replies)."
  (if (uid= (uid thisnode) (car (args msg)))
      (handoff-to-application-handlers thisnode msg (lambda (msg) (cdr (args msg))))
      ; thisnode becomes new source for forwarding purposes
      (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg) (graphID msg)))))

(defmethod k-multicast ((msg solicitation) thisnode srcuid)
  "Announce a message to the collective. Application message is expected to be in args of the solicitation.
  Every intermediate node will have the message
  both delivered to it AND forwarded through it.
  Recipient nodes are not expected to reply (at least not with builtin gossip-style replies)."
  (handoff-to-application-handlers thisnode msg 'args)
   ; thisnode becomes new source for forwarding purposes
  (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg) (graphID msg))))

(defmethod k-hello ((msg solicitation) thisnode srcuid)
  "Announce a UID, IP address, and port to the collective.
  (This is different from the automatic ensure-proxy-node that happens with every incoming
   connection because that implicitly proxifies only the immediate upstream sender.
   This explicitly proxifies a particular node.)*
  Every intermediate node will have the message both delivered to it and forwarded through it.
  Recipient nodes are not expected to reply."
  (destructuring-bind (uid ipaddr ipport) (args msg)
    (ensure-proxy-node :tcp ipaddr ipport uid)
    ; thisnode becomes new source for forwarding purposes
    (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg) (graphID msg)))))

;;; *automatically-created ensure-proxy-nodes probably need to go away--even for solicitations expecting replies--
;;;    because solicitations expecting replies themselves need to go away.

(defmethod k-dissolve ((msg solicitation) thisnode srcuid)
  "Commands every node it passes through to dissolve connections associated with a given graphID.
   Always uses full neighborcast, no matter what the message says."
  (forward msg thisnode (get-downstream thisnode srcuid t (graphID msg)))
  ; must dissolve _after_ forwarding, of course
  (dissolve-neighborhood thisnode (graphID msg)))

;;; NOT DONE YET
(defmethod k-connect ((msg solicitation) thisnode srcuid)
  "Tells nodes this message passes through to connect to each other with given graphID"
  )

;;; Message kinds used by gossip itself

(defmethod gossip-relate ((msg solicitation) thisnode srcuid)
  "Establishes a global non-unique key/value pair. If key currently has a value or set of values,
   new value will be added to the set; it won't replace them.
  Sets value on this node and then forwards 
  solicitation to other nodes, if any.
  No reply expected."
  (destructuring-bind (key value &rest other) (args msg)
    (declare (ignore other))
    (setf (local-kvs thisnode) (kvs:relate (local-kvs thisnode) key value))
    ; thisnode becomes new source for forwarding purposes
    (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg) (graphID msg)))))

(defmethod gossip-relate-unique ((msg solicitation) thisnode srcuid)
  "Establishes a global unique key/value pair. [Unique means there will be only one value for this key.]
  Sets value on this node and then forwards 
  solicitation to other nodes, if any. This is a destructive operation --
  any node that currently has a value for the given key will have that value replaced.
  No reply expected."
  (destructuring-bind (key value &rest other) (args msg)
    (declare (ignore other))
    (setf (local-kvs thisnode) (kvs:relate-unique (local-kvs thisnode) key value))
    ; thisnode becomes new source for forwarding purposes
    (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg) (graphID msg)))))

(defmethod gossip-remove-key ((msg solicitation) thisnode srcuid)
  "Remove a global key/value pair. Removes key/value pair on this node and then forwards 
   solicitation to other nodes, if any. This is a destructive operation --
   any node that currently has the given key will have that key/value removed.
   There's no harm in calling this more than once with the same key; if key
   wasn't present in the first place, this is a no-op.
   No reply expected."
  (let ((key (first (args msg))))
    (kvs:remove-key! (local-kvs thisnode) key)
    ; thisnode becomes new source for forwarding purposes
    (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg) (graphID msg)))))

(defmethod gossip-tally ((msg solicitation) thisnode srcuid)
  "Increment the value of a given key by an increment amount.
   If no value for that key exists currently, set it to 1.
   No reply expected."
  (let ((key (first (args msg)))
        (increment (second (args msg))))
    (setf (local-kvs thisnode) (kvs:tally (local-kvs thisnode) key increment))
    ; thisnode becomes new source for forwarding purposes
    (forward msg thisnode (get-downstream thisnode srcuid (forward-to msg) (graphID msg)))))

;;; TODO: add this to key-value-store
(defmethod tally-nondestructive ((store list) key amount &key (test #'equal))
  "Utility function. Purely functional version of kvs:tally. Only works on alists.
  Increments the key . value pair in alist indicated by key, by the indicated amount.
  If such a pair doesn't exist, create it."
  (let* ((found nil)
         (result (mapcar (lambda (pair)
                           (if (funcall test key (car pair))
                               (progn
                                 (setf found t)
                                 (cons key (+ (cdr pair) amount)))
                               pair))
                         store)))
    (if found
        result
        (acons key amount result))))

(defun multiple-tally (alist1 alist2)
  "Utility function. Given two alists like ((key1 . n1) (key2 . n2) ...)
  call kvs:tally for all pairs in alist."
  (let ((output nil))
    (dolist (pair alist2)
      (setf output (tally-nondestructive alist1 (car pair) (cdr pair))))
    output))

;; REPLY-NECESSARY methods. Three methods per message. The generic ones should handle most if not all cases.


;; We assume that we must coalesce results any time we expect replies from downstream nodes, whether the message
;;   says reply-to == :UPSTREAM or reply-to == (uid thisnode).
;; But of course if there are NO downstream nodes, we cannot expect any replies by definition, so coalescence is not necessary.
(defmethod generic-srr-handler ((msg solicitation) (thisnode gossip-node) srcuid)
  "Generic handler for solicitations requiring replies (SRRs)"
  (let* ((kind (kind msg))
         (soluid (uid msg))
         (downstream (get-downstream thisnode srcuid (forward-to msg) (graphID msg))) ; don't forward to the source of this solicitation
         (timer nil)
         (seconds-to-wait *max-seconds-to-wait*)
         (cleanup (make-timeout-handler thisnode msg kind)))
    (flet ((initialize-reply-cache ()
             "Set up node's reply-cache with initial-reply-value for this message"
             (kvs:relate-unique! (reply-cache thisnode) (vec-repr:bev-vec soluid) (initial-reply-value kind thisnode (args msg))))
           
           (must-coalesce? ()
             "Returns true if this node must coalesce any incoming replies.
             If nil, there is no possibility of repliers, so no coalescence is needed."
             (or (eql :UPSTREAM (reply-to msg))
                 (and (uid? (reply-to msg)) ; check for potential direct replies back to this node
                      (uid= (reply-to msg) (uid thisnode))))))
      ; Always initialize the reply cache--even if there are no downstream nodes--because we assume that if this
      ;   node could potentially be replied to, it itself is always considered a participant node of the message.
      (when (must-coalesce?) (initialize-reply-cache))
      
      ;;; It's possible for there to be a downstream but have no potential repliers. In that case
      ;;; we need to go ahead and reply.
      
      ;;; It's never necessary to coalesce when there's no downstream, because there won't be anything TO coalesce in that case.
      ;;; It MAY not be necessary to coalesce even when there IS a downstream (that's the case for direct replies where this node
      ;;;   is not the node to reply to).
      
      (cond (downstream
             (cond ((must-coalesce?)
                    (if (eql :UPSTREAM (reply-to msg)) ; See Note D
                        (progn
                          (prepare-repliers thisnode soluid downstream)
                          (edebug 3 thisnode thisnode :WAITING msg downstream))
                        (progn ; not :UPSTREAM. Repliers will be anonymous.
                          (setf seconds-to-wait *direct-reply-max-seconds-to-wait*)
                          (edebug 1 thisnode :WAITING msg :ANONYMOUS)
                          (kvs:relate-unique! (repliers-expected thisnode) (vec-repr:bev-vec soluid) :ANONYMOUS)))
                    (forward msg thisnode downstream)
                    ; wait a finite time for all replies
                    (setf timer (schedule-gossip-timeout (ceiling seconds-to-wait) (actor thisnode) soluid))
                    (kvs:relate-unique! (timers thisnode) (vec-repr:bev-vec soluid) timer)
                    (kvs:relate-unique! (timeout-handlers thisnode) (vec-repr:bev-vec soluid) cleanup) ; bind timeout handler
                    ;(edebug 1 thisnode :WAITING msg (ceiling *max-seconds-to-wait*) downstream)
                    )
                   (t ; just forward the message since there won't be an :UPSTREAM reply
                    (forward msg thisnode downstream)
                    ; No cleanup necessary because even though we had a downstream, we never expected any replies.
                    (send-final-reply thisnode (reply-to msg) soluid kind (initial-reply-value kind thisnode (args msg))))))
            (t ; No downstream. This is a leaf node. No coalescence is possible, which implies no cleanup is necessary.
             (send-final-reply thisnode (reply-to msg) soluid kind (initial-reply-value kind thisnode (args msg))))))))

; No node should ever receive an interim or final reply unless it was expecting one by virtue
;  of the original solicitation having a reply-to slot of :UPSTREAM or the UID of the node itself.
;  So there's no special handling in the methods for interim-reply or final-reply of other reply modes.
;  Besides, :GOSSIP and :NEIGHBORCAST reply modes will never cause the creation of a true reply message anyway.
(defmethod generic-srr-handler ((msg interim-reply) (thisnode gossip-node) srcuid)
  (let ((kind (kind msg))
        (soluid (solicitation-uid msg)))
    ; First record the data in the reply appropriately
    (unless (eql :ANONYMOUS (kvs:lookup-key (repliers-expected thisnode) (vec-repr:bev-vec soluid))) ; ignore interim-replies to anonymous expectations
      (when (record-interim-reply msg thisnode soluid srcuid) ; true if this reply is later than previous
        ; coalesce all known data and send it upstream as another interim reply.
        ; (if this reply is not later, drop it on the floor)
        (if *delay-interim-replies*
            (send-delayed-interim-reply thisnode kind soluid)
            (let ((upstream-source (get-upstream-source thisnode (solicitation-uid msg))))
              (send-interim-reply thisnode kind soluid upstream-source)))))))

(defun run-coalescer (coalescer local-data new-data)
  (funcall coalescer local-data new-data))

(defmethod generic-srr-handler ((msg final-reply) (thisnode gossip-node) srcuid)
  (edebug 1 :generic-srr-handler :final-reply msg thisnode)
  (let* ((kind (kind msg))
         (soluid (solicitation-uid msg))
         (local-data (kvs:lookup-key (reply-cache thisnode) (vec-repr:bev-vec soluid)))
         (coalescer (coalescer kind)))
    ; Any time we get a final reply, we destructively coalesce its data into local reply-cache
    (kvs:relate-unique! (reply-cache thisnode)
                        (vec-repr:bev-vec soluid)
                        (run-coalescer coalescer local-data (first (args msg))))
    (cancel-replier thisnode kind soluid srcuid)))

(defgeneric initial-reply-value (kind thisnode msgargs)
  (:documentation "Initial the reply-value for the given kind of message. Must return an augmented-data object."))

(defmethod maybe-augment-datum ((datum augmented-data) kind)
  (declare (ignore kind))
  datum)

(defmethod maybe-augment-datum (datum kind)
  (augment datum `((:kind . ,kind) (:eripa . ,(eripa)) (:port . ,*actual-tcp-gossip-port*))))

(defmethod initial-reply-value :around (kind thisnode msgargs)
  "Ensure an augmented-data object is getting returned."
  (declare (ignore thisnode msgargs))
  (let ((datum (call-next-method)))
    (maybe-augment-datum datum kind)))

(defmethod initial-reply-value ((kind (eql :gossip-lookup-key)) (thisnode gossip-node) msgargs)
  (let* ((key (first msgargs))
         (myvalue (kvs:lookup-key (local-kvs thisnode) key)))
    (list (cons myvalue 1))))

(defmethod initial-reply-value ((kind (eql :count-alive)) (thisnode gossip-node) msgargs)
  (declare (ignore msgargs))
  1)

(defmethod initial-reply-value ((kind (eql :list-alive)) (thisnode gossip-node) msgargs)
  (declare (ignore msgargs))
  (list (uid thisnode)))

(defmethod initial-reply-value ((kind (eql :find-max)) (thisnode gossip-node) msgargs)
  (let ((key (first msgargs)))
    (kvs:lookup-key (local-kvs thisnode) key)))

(defmethod initial-reply-value ((kind (eql :find-min)) (thisnode gossip-node) msgargs)
  (let ((key (first msgargs)))
    (kvs:lookup-key (local-kvs thisnode) key)))

(defmethod count-alive ((msg gossip-message-mixin) (thisnode gossip-node) srcuid)
  "Return total count of nodes that received the message."
  (generic-srr-handler msg thisnode srcuid))

(defmethod list-alive ((msg gossip-message-mixin) (thisnode gossip-node) srcuid)
  "Like count-alive but this returns an actual list of node UIDs that received the message."
  (generic-srr-handler msg thisnode srcuid))

(defmethod gossip-lookup-key ((msg gossip-message-mixin) (thisnode gossip-node) srcuid)
  "Lookup value of given key. Returns an alist of ((value1 . count1) (value2 . count2) ...)
   where valuex is a value found associated with the key and countx is the number of nodes with
   that value."
  (generic-srr-handler msg thisnode srcuid))

(defmethod find-max ((msg gossip-message-mixin) thisnode srcuid)
  "Retrieve maximum value of a given key on all the nodes. Non-numeric values are ignored."
  (generic-srr-handler msg thisnode srcuid))

(defmethod find-min ((msg gossip-message-mixin) thisnode srcuid)
  "Retrieve minimum value of a given key on all nodes"
  (generic-srr-handler msg thisnode srcuid))

;;; END OF GOSSIP METHODS

;;; REPLY SUPPORT ROUTINES

(defun send-final-reply (srcnode destination soluid kind data)
  "Return nil if successful; an error object otherwise."
  (let ((reply (make-final-reply :solicitation-uid soluid
                                 :kind kind
                                 :args (list data)))
        (where-to-send-reply (cond ((uid? destination)
                                    destination)
                                   ((eql :UPSTREAM destination)
                                    (get-upstream-source srcnode soluid))
                                   (t destination))))
    (cond ((uid? where-to-send-reply) ; should be a uid or T. Might be nil if there's a bug.
           (edebug 1 srcnode :FINALREPLY soluid :TO where-to-send-reply data)
           (send-msg reply
                     where-to-send-reply
                     (uid srcnode)))
          ; if no place left to reply to, just log the result.
          ;   This can mean that srcnode autonomously initiated the request, or
          ;   somebody running the sim told it to.
          ((or (null where-to-send-reply)
               (eql t where-to-send-reply))
           (let ((e (make-condition 'no-reply-destination
                                    :reply reply
                                    :soluid soluid
                                    :data data)))
             (edebug 1 :error "No Reply Destination" e)
             e))
          (t
           (edebug 1 srcnode :FINALREPLY soluid :TO where-to-send-reply data)
           (actor-send where-to-send-reply reply)))))

(defun coalesce&reply (reply-to thisnode reply-kind soluid)
  "Generic cleanup function needed for any message after all final replies have come in or
  timeout has happened. Only for upstream [reduce-style] replies; don't use otherwise.
  Cleans up reply tables and reply upstream with final reply containing coalesced data.
  Assumes any timers have already been cleaned up."
  (let ((coalesced-data ;(kvs:lookup-key (reply-cache thisnode) (vec-repr:bev-vec soluid))) ; will already have been coalesced here
         (coalesce thisnode reply-kind soluid))) ; won't have already been coalesced if we timed out!
    ; clean up reply tables.
    (kvs:remove-key (repliers-expected thisnode) (vec-repr:bev-vec soluid)) ; might not have been done if we timed out
    (kvs:remove-key (reply-cache thisnode) (vec-repr:bev-vec soluid))
    (kvs:remove-key (timers thisnode) (vec-repr:bev-vec soluid))
    (kvs:remove-key (timeout-handlers thisnode) (vec-repr:bev-vec soluid))
    ; must create a new reply here; cannot reuse an old one because its content has changed
    (send-final-reply 
     thisnode
     (if (uid? reply-to)
         (if (uid= reply-to (uid thisnode)) ; can't send a reply to myself, so punt and send it upstream
             :UPSTREAM
             reply-to)
         reply-to)
     soluid reply-kind coalesced-data)
    coalesced-data ; mostly for debugging
    ))

(defun send-interim-reply (thisnode reply-kind soluid where-to-send-reply)
  "Send an interim reply, right now."
  ; Don't ever call this for replies to :ANONYMOUS expectations. See Note C.
  (let ((coalesced-data (coalesce thisnode reply-kind soluid)))
    (if (uid? where-to-send-reply) ; should be a uid or T. Might be nil if there's a bug.
        (let ((reply (make-interim-reply :solicitation-uid soluid
                                         :kind reply-kind
                                         :args (list coalesced-data))))
          (edebug 4 thisnode :SEND-INTERIM-REPLY reply :to where-to-send-reply coalesced-data)
          (send-msg reply
                    where-to-send-reply
                    (uid thisnode)))
        ; if no place left to reply to, just log the result.
        ;   This can mean that thisnode autonomously initiated the request, or
        ;   somebody running the sim told it to.
        (edebug 4 thisnode :INTERIMREPLY soluid coalesced-data))))

(defun send-delayed-interim-reply (thisnode reply-kind soluid)
  "Called by a node actor to tell itself (or another actor, but we never do that now)
  to maybe send an interim reply after it processes any possible interim messages, which
  could themselves obviate the need for an interim reply."
  ; Should we make these things be yet another class with solicitation-uid-slot?
  ; Or just make a general class of administrative messages with timeout being one?
  (let ((msg (make-solicitation
              :kind :maybe-sir
              :args (list soluid reply-kind))))
    (edebug 4 thisnode :ECHO-MAYBE-SIR nil)
    (send-self msg)))

(defun later-reply? (new old)
  "Returns true if old is nil or new has a later timestamp"
  (or (null old)
      (> (timestamp new) (timestamp old))))

;;; Memorizing previous replies
(defmethod set-previous-reply ((node gossip-node) soluid srcuid reply)
  "Remember interim reply indexed by soluid and srcuid"
  ; Don't ever call this for replies to :ANONYMOUS expectations. See Note C.
  (let ((interim-table (kvs:lookup-key (repliers-expected node) (vec-repr:bev-vec soluid))))
    (unless interim-table
      (setf interim-table (kvs:make-store ':hashtable :test 'equalp))
      (kvs:relate-unique! (repliers-expected node) (vec-repr:bev-vec soluid) interim-table))
    (kvs:relate-unique! interim-table (vec-repr:bev-vec srcuid) reply)))

(defmethod get-previous-reply ((node gossip-node) soluid srcuid)
  "Retrieve interim reply indexed by soluid and srcuid"
  ; Don't ever call this for replies to :ANONYMOUS expectations. See Note C.
  (let ((interim-table (kvs:lookup-key (repliers-expected node) (vec-repr:bev-vec soluid))))
    (when interim-table
      (kvs:lookup-key interim-table (vec-repr:bev-vec srcuid)))))

(defmethod remove-previous-reply ((node gossip-node) soluid srcuid)
  "Remove interim reply (if any) indexed by soluid and srcuid from repliers-expected table.
  Return true if table is now empty; false if any other expected repliers remain.
  Second value is true if given soluid and srcuid was indeed present in repliers-expected."
  ; Don't ever call this for replies to :ANONYMOUS expectations. See Note C.
  (let ((interim-table (kvs:lookup-key (repliers-expected node) (vec-repr:bev-vec soluid))))
    (unless interim-table
      (return-from remove-previous-reply (values t nil))) ; no table found. Happens for soluids where no replies were ever expected.
    (multiple-value-bind (store was-present?)
                         (kvs:remove-key! interim-table (vec-repr:bev-vec srcuid)) ; whatever was there before should have been nil or an interim-reply, but we're not checking for that
      (declare (ignore store))
      (cond ((zerop (hash-table-count interim-table))
             ; if this is the last reply, kill the whole table for this soluid and return true
             ;; (edebug 1 node :KILL-TABLE-1 nil)
             (kvs:remove-key! (repliers-expected node) (vec-repr:bev-vec soluid))
             (values t was-present?))
            (t (values nil was-present?))))))

(defun record-interim-reply (new-reply node soluid srcuid)
  "Record new-reply for given soluid and srcuid on given node.
  If new-reply is later or first one, replace old and return true.
  Otherwise return false."
  ; Don't ever call this for replies to :ANONYMOUS expectations. See Note C.
  (let* ((previous-interim (get-previous-reply node soluid srcuid)))
    (when (or (null previous-interim)
              (later-reply? new-reply previous-interim))
      (set-previous-reply node soluid srcuid new-reply)
      t)))

(defgeneric data-coalescer (kind)
  (:documentation "Coalescer (reducer) for two arguments for a given kind of reply."))

(defmethod data-coalescer ((kind (eql :COUNT-ALIVE)))
  "Proper coalescer for :count-alive responses."
  '+)

(defmethod data-coalescer ((kind (eql :LIST-ALIVE)))
  "Proper coalescer for :list-alive responses. Might
   want to add a call to remove-duplicates here if we start
   using a gossip protocol not guaranteed to ignore redundancies)."
  'append)

(defmethod data-coalescer ((kind (eql :GOSSIP-LOOKUP-KEY)))
  "Proper coalescer for :GOSSIP-LOOKUP-KEY responses."
  'multiple-tally)

(defmethod data-coalescer ((kind (eql :FIND-MAX)))
  (lambda (x y) (cond ((and (numberp x)
                            (numberp y))
                       (max x y))
                      ((numberp x)
                       x)
                      ((numberp y)
                       y)
                      (t nil))))

(defmethod data-coalescer ((kind (eql :FIND-MIN)))
  (lambda (x y) (cond ((and (numberp x)
                            (numberp y))
                       (min x y))
                      ((numberp x)
                       x)
                      ((numberp y)
                       y)
                      (t nil))))

(defmethod coalesce ((node gossip-node) kind soluid)
  "Grab all the data that interim repliers have sent me so far, combine it with my
  local reply-cache in a way that's specific to kind, and return result.
  This purely functional and does not change reply-cache.
  This is essentially a reduce operation but of course we can't use that name."
  (let* ((local-data    (kvs:lookup-key (reply-cache node) (vec-repr:bev-vec soluid)))
         (interim-table (kvs:lookup-key (repliers-expected node) (vec-repr:bev-vec soluid)))
         (interim-data (when (and interim-table
                                  (hash-table-p interim-table))
                         (loop for reply being each hash-value of interim-table
                           when reply collect (first (args reply)))))
         (coalescer (coalescer kind)))
    (edebug 5 node :COALESCE interim-data (unwrap local-data) interim-table)
    (let ((coalesced-output
           (reduce coalescer
                   interim-data
                   :initial-value local-data)))
      (edebug 5 node :COALESCED-OUTPUT (unwrap coalesced-output))
      coalesced-output)))

(defun cancel-replier (thisnode reply-kind soluid srcuid)
  "Actions to take when a replier should be canceled.
  If no more repliers, reply upstream with final reply.
  If more repliers, reply upstream either immediately or after a yield period with an interim-reply.
  Returns true if a [now-cancelled] reply had been expected from soluid/srcuid."
  (let ((interim-table (kvs:lookup-key (repliers-expected thisnode) (vec-repr:bev-vec soluid))))
    (cond ((eql :ANONYMOUS interim-table)
           nil) ; do nothing and return nil if we're accepting :ANONYMOUS replies
          (t (multiple-value-bind (no-more-repliers was-present?) (remove-previous-reply thisnode soluid srcuid)
               (cond (no-more-repliers
                      (let ((timeout-handler (kvs:lookup-key (timeout-handlers thisnode) (vec-repr:bev-vec soluid))))
                        (if timeout-handler ; will be nil for messages that don't expect a reply
                            (funcall timeout-handler nil)
                            (edebug 5 thisnode :NO-TIMEOUT-HANDLER! soluid)
                            )))
                     (t ; more repliers are expected
                      ; functionally coalesce all known data and send it upstream as another interim reply
                      (if *delay-interim-replies*
                          (send-delayed-interim-reply thisnode reply-kind soluid)
                          (let ((upstream-source (get-upstream-source thisnode soluid)))
                            (send-interim-reply thisnode reply-kind soluid upstream-source)))))
               was-present?)))))

;;;; END OF REPLY SUPPORT ROUTINES

; For debugging list-alive
(defun missing? (alive-list)
  "Returns a list of node UIDs that are missing from a list returned by list-alive"
  (let ((dead-list nil))
    (maphash (lambda (key value)
               (declare (ignore value))
               (unless (member key alive-list :test 'equalp)
                 (push key dead-list)))
             *nodes*)
    dead-list))

;;;; Network communications

(defun ensure-proxy-node (mode real-address real-port real-uid &optional (temporary-p nil))
  "Real-address, real-port, and real-uid refer to the node on an OTHER machine that this node points to.
  Returns newly-created or old proxy-gossip-node, if any.
  This is very conservative: It will never replace an existing real node of a given UID with a proxy node,
  and it will never replace an existing proxy node of a given UID with a new one.
  Newly-created proxy (if any) will be added to *nodes* database for this process.
  If successful, proxy (new or existing) will be returned.
  If proxy could not be found nor made for some reason, returns NIL."
  (check-type real-port integer) ; might want to support lookup of port-name to port-number eventually
  (let* ((oldnode nil) 
         (proxy nil))
    (flet ((make-proxy ()
             (if (and (eql real-port *actual-tcp-gossip-port*)
                      (or (usocket:ip= real-address (eripa))
                          (usocket:ip= real-address #(127 0 0 1))
                          (usocket:ip= real-address "localhost")))
                 (edebug 1 :ERROR "Proxy IP address and port match those of this process. Shouldn't happen."
                         real-address real-port)
                 (setf proxy (make-proxy-node mode
                                              :real-address real-address
                                              :real-port real-port
                                              :real-uid real-uid
                                              :temporary-p temporary-p)))))
      (setf oldnode
            (if (eql 0 real-uid)
                (proxy-to-host real-address real-port)
                (lookup-node real-uid))) ; proxy uids should match their real-uids if /= 0
      (cond ((and oldnode
                  (not (typep oldnode 'proxy-gossip-node)))
             (edebug 1 :WARN oldnode "Expected proxy; found real node. Doing nothing." real-uid))
            (oldnode (setf proxy oldnode))
            (t (make-proxy)))
      proxy)))

(defmethod ensure-proxy-from-ad ((monad t))
  nil)

(defmethod ensure-proxy-from-ad ((monad augmented-data))
  "Given an augmented-data, make a proxy from it if it contains enough metadata to do so.
  [Calling bind here is cheating because we're not returning another monad.
  We're side-effecting, not composing. But it's easy.]"
  (let ((proxies nil)) ; just so we have some output data to trace
    (bind (lambda (data metadata)
            (let* ((address (when metadata (cdr (assoc :eripa metadata))))
                   (port    (when metadata (cdr (assoc :port metadata)))))
              (when (and address port)
                (dolist (uid data) ; this will usually be a singleton list, but it doesn't have to be
                  (pushnew (ensure-proxy-node :TCP address port uid nil) proxies)))))
          monad)
    proxies))

(defun ensure-proxies (adlist)
  "Ensures a proxy exists for each UID in each augmented-datum in adlist"
  (dolist (ad adlist)
    (ensure-proxy-from-ad ad)))

(defmethod incoming-message-handler ((msg gossip-message-mixin) srcuid destuid)
  "Locally dispatch messages received from network"
  ;; srcuid will be that of a proxy-gossip-node on receiver (this) machine, and also that of the (remote) 
  ;;   real node the proxy points to
  ;; destuid will be that of a true gossip-node on receiver (this) machine
  (incf (hopcount msg)) ; no need to copy message here since we just created it from scratch
  (send-msg msg destuid srcuid)
  t)

;; ------------------------------------------------------------------------------

;;;
;;; Transport interface
;;;

(defun start-gossip-transport (&optional (address nil) (port nil))
  "Start the Gossip Transport network endpoint (if not already started.)
  ADDRESS and/or PORT can be supplied to bind the endpoint to a
  specific address, otherwise an available address will be assigned
  automatically."
  (when (null *transport*)
    (setf *transport*
          (gossip/transport:start-transport :address address
                                            :port port
                                            :message-received-hook 'transport-message-received
                                            :peer-up-hook 'transport-peer-up
                                            :peer-down-hook 'transport-peer-down))
    (setf *actual-tcp-gossip-port* port)
    *transport*))

(defun transport-message-received (message)
  "Callback for transport layer on incoming message from other node."
  (with-authenticated-packet (packet)
    message ; has already been deserialized at this point
    ;; Unpack envelope containing Gossip metadata.
    (destructuring-bind (destuid srcuid rem-address rem-port msg) packet ;; see Note G
      (edebug 1 "Gossip transport message received" rem-address rem-port)
      ;; Note: Protocol should not be hard-coded. Supply from transport layer? -lukego
      (when (typep msg 'solicitation) ; only make proxies for solicitations; never replies
        (let ((reply-to (reply-to msg))) ; and even then, only make proxies for solicitations that expect replies,
          ;  and even then, make the proxy be temporary so it won't be found by
          ;  e.g. #'uber-set
          (when (or (uid? reply-to) ; if reply-to is nil or not one of these, we don't need a proxy to reply to
                    (eql :UPSTREAM reply-to))
            (let ((proxy (ensure-proxy-node :tcp rem-address rem-port srcuid t)))
              ; if we needed a proxy for replies and failed to make one (or find one), then
              ;   an error happened, so drop the whole message on the floor.
              (unless proxy
                (edebug 1 :ERROR "Dropped message because proxy for reply couldn't be made" msg)
                (return-from transport-message-received nil))))))
      (incoming-message-handler msg srcuid destuid))))

(defun transport-peer-up (peer-address peer-port)
  "Callback for transport layer event."
  (edebug 1 :TRANSPORT "Transport connection to peer established" peer-address peer-port))

(defun transport-peer-down (peer-address peer-port reason)
  "Callback for transport layer event."
  (edebug 1 :TRANSPORT "Transport connection to peer failed" peer-address peer-port reason))

(defun shutdown-gossip-server ()
  "Stop the Gossip Transport network endpoint (if currently running)."
  (unless (null *transport*)
    (gossip/transport:stop-transport *transport*)
    (setf *transport* nil)))

;; ------------------------------------------------------------------------------
;; We need to authenticate all messages being sent over socket ports
;; from this running Lisp image. Give us some signing keys to do so...

;;; The need for this is rather dubious.  No one other than the
;;; signing node can authenticate this HMAC. 

(defun actor-keypair-fn (cmd &rest args)
  "Test-and-set function that the *hmac-keypair-actor* runs.
  It's critical that only one actor run pbc:make-key-pair at a time"
  (declare (ignore cmd)) ; everything is interpreted as :TAS
  (destructuring-bind (mbox &rest other) args
    (declare (ignore other))
    (unless *hmac-keypair*
      (setf *hmac-keypair* (pbc:make-key-pair (list :port-authority (uuid:make-v1-uuid)))))
    (actor-send mbox *hmac-keypair*)))

#+IGNORE
(defun hmac-keypair ()
  (or *hmac-keypair*
      (let ((mbox (mpcompat:make-mailbox)))
        (actor-send *hmac-keypair-actor* :TAS mbox)
        (first (mpcompat:mailbox-read mbox)))))

(defun hmac-keypair ()
  (mpcompat:with-lock (*hmac-keypair-lock*)
    (or *hmac-keypair*
        (setf *hmac-keypair* (pbc:make-key-pair (list :port-authority (uuid:make-v1-uuid)))))))

(defun sign-message (msg)
  "Sign and return an authenticated message packet. Packet includes
  original message."
  (let ((keypair (hmac-keypair)))
    (assert (pbc:check-public-key (pbc:keying-triple-pkey keypair)
                                  (pbc:keying-triple-sig  keypair)))
    (pbc:sign-message msg
                      (pbc:keying-triple-pkey keypair)
                      (pbc:keying-triple-skey keypair))))

;; ------------------------------------------------------------------------------

(defmethod deliver-gossip-msg (gossip-msg (node proxy-gossip-node) srcuid)
  "This node is a standin for a remote node. Transmit message across network."
  (gossip/transport:transmit *transport*
                             (real-address node)
                             (real-port node) 
                             ;; Pack message in a signed envelope containing Gossip metadata.
                             ;; See Note G.
                             (sign-message (list (real-uid node) ; destuid
                                                 srcuid          ; srcuid
                                                 (eripa)
                                                 *actual-tcp-gossip-port*
                                                 gossip-msg))))  ; message (payload)

(defmethod deliver-gossip-msg (gossip-msg (node gossip-node) srcuid)
  (setf gossip-msg (copy-message gossip-msg)) ; must copy before incrementing hopcount because we can't
  ;  modify the original without affecting other threads.
  (incf (hopcount gossip-msg))
  ; Remember the srcuid that sent me this message, because that's where reply (if any) might be forwarded to
  (locally-receive-msg gossip-msg node srcuid))

(defmethod deliver-gossip-msg ((gossip-msg system-async) (node abstract-gossip-node) srcuid)
  (setf gossip-msg (copy-message gossip-msg)) ; must copy before incrementing hopcount because we can't
  ;  modify the original without affecting other threads.
  (incf (hopcount gossip-msg))
  ; Remember the srcuid that sent me this message, because that's where reply (if any) might be forwarded to
  ;  (although system-async messages never expect replies).
  (locally-receive-msg gossip-msg node srcuid))

(defun run-gossip (&optional (archive-log t))
  "Archive the current log and clear it.
   Prepare all nodes for new simulation.
   Only necessary to call this once, or
   again if you change the graph or want to start with a clean log."
  (gossip-init ':maybe)
  (when archive-log (archive-log))
  (sleep .5)
  (start-gossip-transport usocket:*wildcard-host*
                          (emotiq/config:setting :gossip-server-port))
  (maphash (lambda (uid node)
             (declare (ignore uid))
             (setf (car (ac::actor-busy (actor node))) nil)
             (clear-caches node))
           *nodes*)
  (hash-table-count *nodes*))

(defun measure-timing (logcmd &optional (log *log*))
  "Returns maximum time elapsed between first log entry [of any type] and last of type logcmd.
   It's a good idea to call #'archive-log before using this to ensure you start with a fresh log.
   Assumes first element of every log entry is a timestamp with microsecond resolution."
  (let ((lastpos (position logcmd log :from-end t :key 'second)))
    (when lastpos
      (/ (- (first (elt log lastpos))
            (first (elt log 0)))
         1e6))))

(defun log-histogram (&optional (log *log*))
  "Returns a histogram (as an alist) of given log by the keyword after the timestamp"
  (let ((table (kvs:make-store :hashtable))
        (alist nil))
    (loop for msg across log do
      (kvs:tally table (second msg) 1))
    (setf alist (alistify-hashtable table))
    (sort alist #'> :key #'cdr)))

; Ex:
; (archive-log)
; (solicit-wait <something>)
; (measure-timing :finalreply)

; (make-graph 10)
; (save-graph-to-file "tests/10nodes2.lisp")
; (restore-graph-from-file "tests/10nodes2.lisp") ;;; best test network
; (make-graph 5)
; (save-graph-to-file "~/gossip/5nodes.lisp")
; (restore-graph-from-file "~/gossip/5nodes.lisp")

; (make-graph 100)
; (make-graph 1000)
; (make-graph 10000)
; (visualize-nodes)  ; probably not a great idea for >100 nodes

; PARTIAL GOSSIP TESTS
; (make-graph 10)
; (set-protocol-style :gossip 2)
; (get-protocol-style)
; (run-gossip)
; (solicit-wait (random-node) :count-alive)
; (solicit-wait (random-node) :list-alive)
; (visualize-nodes)
; (inspect *log*)

(defun other-udp-port ()
  (when *udp-gossip-socket*
    (let ((gossip-port (emotiq/config:setting :gossip-server-port)))
      (if (= gossip-port *actual-udp-gossip-port*)
        (1+ gossip-port)
        gossip-port))))

(defun other-tcp-port ()
  "Deduce proper port for other end of connection based on whether this process
   has already established one. Only used for testing two processes communicating on one machine."
  (when *tcp-gossip-socket*
    (let ((gossip-port (emotiq/config:setting :gossip-server-port)))
      (if (= gossip-port *actual-tcp-gossip-port*)
          (1+ gossip-port)
          gossip-port))))
    
; UDP TESTS
; Test 1
; ON SERVER MACHINE
; (clear-local-nodes)
#+TEST1
(setf localnode (make-node ':gossip :temporary-p t
  :UID 200))
; (run-gossip :UDP)

; ON CLIENT MACHINE
; (clear-local-nodes)
; (run-gossip :UDP)
#+TEST-LOCALHOST
(setf rnode (ensure-proxy-node ':UDP "localhost" (other-udp-port) 200)) ; assumes there's a node numbered 200 on another Lisp process at 65003
#+TEST-AMAZON
(setf rnode (ensure-proxy-node ':UDP "ec2-35-157-133-208.eu-central-1.compute.amazonaws.com" (emotiq/config:setting :gossip-server-port 200)))


#+TEST1 ; create 'real' local node to call solicit-wait on because otherwise system will try to forward the
       ;   continuation that solicit-wait makes across the network
(setf localnode (make-node ':gossip :temporary-p t
  :UID 201))
#+TEST1
(pushnew (uid rnode) (neighborhood localnode))
; (solicit-wait localnode :count-alive)
; (solicit-wait localnode :list-alive)
; (solicit localnode :gossip-relate-unique :foo :bar)
; (solicit-wait localnode :gossip-lookup-key :foo)

; Test 2: List live nodes at given address
; ; ON SERVER MACHINE
; (clear-local-nodes)
; (make-graph 10)
; (run-gossip :UDP)

; ON CLIENT MACHINE
; (clear-local-nodes)
; (run-gossip :UDP)
; (set-protocol-style :neighborcast)
#+TEST-LOCALHOST
(setf rnode (ensure-proxy-node ':UDP "localhost" (other-udp-port) 0))
#+TEST-AMAZON
(setf rnode (ensure-proxy-node ':UDP "ec2-35-157-133-208.eu-central-1.compute.amazonaws.com" (emotiq/config:setting :gossip-server-port) 0))

#+TEST2 ; create 'real' local node to call solicit-wait on because otherwise system will try to forward the
       ;   continuation that solicit-wait makes across the network
(setf localnode (make-node ':gossip :temporary-p t
  :UID 201))
#+TEST2
(pushnew (uid rnode) (neighborhood localnode))

; (solicit-direct localnode :count-alive)
; (solicit-direct localnode :list-alive)
; (inspect *log*)


; Test 3: List live nodes at given address via TCP
; ; ON SERVER MACHINE
; (clear-local-nodes)
; (make-graph 1)
; (run-gossip)

; ON CLIENT MACHINE
; (clear-local-nodes)
; (run-gossip)
; (archive-log)
; (set-protocol-style :neighborcast)
#+TEST-LOCALHOST
(setf rnode (ensure-proxy-node ':TCP "localhost" (other-tcp-port) 0))
#+TEST-AMAZON
(setf rnode (ensure-proxy-node ':TCP "ec2-35-157-133-208.eu-central-1.compute.amazonaws.com" (emotiq/config:setting :gossip-server-port) 0))

#+TEST3 ; create 'real' local node to call solicit-wait on because otherwise system will try to forward the
       ;   continuation that solicit-wait makes across the network
(setf localnode (make-node ':gossip :temporary-p t
  :UID 201))
#+TEST3
(pushnew (uid rnode) (neighborhood localnode))
; (visualize-nodes)
; (solicit-direct localnode :count-alive)
; (solicit-direct localnode :list-alive)
; (solicit-wait localnode :count-alive)
; (solicit-wait localnode :list-alive)
; (inspect *log*)

; (run-gossip)
; (solicit-wait (first (listify-nodes)) :list-alive)
; (solicit-direct (first (listify-nodes)) :list-alive)
; (solicit-direct (first (listify-nodes)) :count-alive)
; (solicit-progress (first (listify-nodes)) :list-alive)
; (solicit-wait (first (listify-nodes)) :count-alive)
; (solicit (first (listify-nodes)) :announce :foo)
; (solicit-wait 340 :list-alive) ; if there happens to be a node with UID 340
; (inspect *log*) --> Should see :FINALREPLY with all nodes (or something slightly less, depending on network delays, etc.) 

; (solicit (first (listify-nodes)) :gossip-relate-unique :foo :bar)
; (solicit-wait (first (listify-nodes)) :gossip-lookup-key :foo)
; (solicit (first (listify-nodes)) :gossip-relate :foo :baz)
; (solicit-wait (first (listify-nodes)) :gossip-lookup-key :foo)

; (set-protocol-style :gossip) ; ensure every node will likely not get the message
; (solicit (first (listify-nodes)) :gossip-relate-unique :foo 2)
; (solicit (second (listify-nodes)) :gossip-relate-unique :foo 17)
; (solicit (third (listify-nodes)) :gossip-relate-unique :foo 5)
; (set-protocol-style :neighborcast)
; (solicit-wait (first (listify-nodes)) :find-max :foo)
; (solicit-wait (first (listify-nodes)) :find-min :foo)

;; should produce something like (:FINALREPLY "node209" "sol255" (((:BAZ :BAR) . 4))) as last *log* entry

(defun get-kvs (key)
  "Shows value of key for all local nodes. Just for debugging. :gossip-lookup-key is the proper way to do this."
  (let ((nodes (listify-nodes)))
    (mapcar (lambda (node)
              (cons node (kvs:lookup-key (local-kvs node) key)))
            nodes)))

; TEST NO-REPLY MESSAGES
; (make-graph 10)
; (run-gossip)
; (solicit (first (listify-nodes)) :gossip-relate-unique :foo :bar)
; (get-kvs :foo) ; should return a list of (node . BAR)
; (solicit (first (listify-nodes)) :gossip-remove-key :foo)
; (get-kvs :foo) ; should just return a list of (node . nil)
; (solicit (first (listify-nodes)) :gossip-tally :foo 1)
; (get-kvs :foo) ; should return a list of (node . 1)
; (solicit (first (listify-nodes)) :gossip-tally :foo 1)
; (get-kvs :foo) ; should return a list of (node . 2)

#+TESTING
(setf node (make-node ':gossip :temporary-p t
  :UID 253
  :LOGFN 'GOSSIP::DEFAULT-LOGGING-FUNCTION
  :KVS (as-hash-table 'eql '((key1 . 1) (key2 . 2) (key3 . 3)))))

#+TESTING
(mapc (lambda (uid)
          (pushnew uid (neighborhood node)))
        '(248 250 251))

#+TESTING
(save-node node *standard-output*)

#+TESTING
(setf msg (make-solicitation :kind :list-alive))
#+TESTING
(copy-message msg)

#| NOTES

NOTE A: About proactive reply cancellation
If node X is ignoring a solicitation* from node Y because it already
saw that solicitation, then it must also not expect a reply from node Y
for that same solicitation.
Here's why [In this scenario, imagine #'locally-receive-msg is acting on behalf of node X]:
If node X ignores a solicition from node Y -- because it's already seen that solicitation --
  then X knows the following:
  1. Node Y did not receive the solicition from X. It must have received it from somewhere else,
     because nodes *never* forward messages to their upstream.
  2. Therefore, if X forwards (or forwarded) the solicitation to Y, Y
     is definitely going to ignore it. Because Y has already seen it.
  3. Therefore (to recap) if X just ignored a solicitation from Y, then X
     knows Y is going to ignore that same solicitation from X.
  4. THEREFORE: X must not expect Y to respond, and that's why
     we call cancel-replier here. If we don't do this, Y will ignore
     and X will eventually time out, which it doesn't need to do.
  5. FURTHERMORE: Y knows X knows this. So it knows X will stop waiting for it.
* we take no special action for non-solicitation messages because they can't
  ever be replied to anyway.

NOTE B: About the repliers-expected slot.
This slot always contains a hashtable mapping a soluid to a value.
The value can be:
--Another hashtable, which maps srcuid to a subvalue. If subvalue is nil, it means this node
  expects a reply from srcuid for the soluid that represents this table. If the subvalue is non-nil,
  it can only be an interim-reply that srcuid has already sent. Future interim-replies from that srcuid
  will supersede older ones. (They will not be coalesced with older interim-replies; they replace them.)
  Subvalue will never be a final-reply because those don't get stored--they get coalesced with the value
  in reply-cache and stored in the reply-cache.
--The keyword :ANONYMOUS which indicates that replies from any srcuid are accepted. We don't expect to
  receive interim-replies from :ANONYMOUS repliers, so if we do receive any, they simply get dropped on
  the floor rather than stored. See Note C for more info.
--The value NIL, which indicates that no replies (or no further replies) are expected for this soluid.


NOTE C: About :ANONYMOUS expectations.
We have a mechanism to allow replies to a node to occur from unpredictable sources. This can happen
when we send a message with forward-to :NEIGHBORCAST or :GOSSIP but whose reply-to slot is a single UID.
In this case, there's no way to know who might reply in advance, so we have to allow replies (to this soluid)
from any srcuid. So in that case, we do
(kvs:relate-unique! (repliers-expected thisnode) (vec-repr:bev-vec soluid) :ANONYMOUS)
to prepare for replies.
There are several implications here:
1. We cannot know in advance when we have received all possible replies. Thus we have to depend on a timeout
as the only mechanism to know when to ignore further replies (and to reply ourselves, if necessary).
Thus for a node expecting :ANONYMOUS replies, we must not call #'prepare-repliers for that node.
2. We don't allow interim-replies to :ANONYMOUS expectations, because we're not creating a table to keep them
(because in place of that table, we just have the keyword :ANONYMOUS), and because I don't think we'll ever need
interim-replies in this case.
3. We still allow coalescence at the node expecting :ANONYMOUS replies; they just always come from final-replies.
4. There's a possible hazard condition here: If a single node sends us two final-replies with the same soluid,
we won't know to reject the second one, and we'll coalesce a value from that node twice, which would cause
an incorrect coalescence result. We may have to care about this in future, but I'm not going to worry about
it now. In working code, there's no code path that would cause a node to respond with a final-reply for a given
soluid twice.

NOTE D: About :ANONYMOUS nodes

#'prepare-repliers is solely for use by a given node X when it is passing along a message whose reply-to slot
is :UPSTREAM. It should never be used for any other kind of reply-to, and in some cases it should not be used even
in the :UPSTREAM case. Read on.

An :ANONYMOUS node is a proxy-node whose real-uid slot contains 0. It stands in for "every node" on some remote
machine. A regular (non-anonymous) proxy-node on machine A masquerades as the source of messages to local nodes on machine A, where
the actual source is actually on machine B. #'ensure-proxy-node is what makes this happen. But it NEVER happens
for :ANONYMOUS nodes. When a remote node on B responds to A, its message always comes in through a regular proxy-node
(which has a nonzero real-uid). Said proxy-node will be automatically created if it doesn't already exist.
Thus :ANONYMOUS nodes are always created manually -- never automatically -- and they're used for bootstrapping
a gossip network. And they're only used for outgoing messages -- never incoming.

Any regular gossip-node X which has an :ANONYMOUS node in its immediate downstream (its neighbors slot) MUST only
expect :ANONYMOUS replies. This is because the presence of even one :ANONYMOUS node in node X's downstream
means that node X can never be sure when all replies have occurred. Thus node X MUST NOT call #'prepare-repliers
in this case -- even if the reply-to happens to be :UPSTREAM.

Note that :ANONYMOUS nodes are essential for bootstrapping a gossip network that spans multiple machines--we
cannot just disallow them.

So why not just let all replies and all proxy-nodes be :ANONYMOUS?
Because with :ANONYMOUS replies, you can't ever be sure when you're done. You have to rely on timeouts to stop
waiting for replies. This is acceptable at boot time, but as proxy nodes for unique remote nodes are automatically
created, it's best to wire those into the gossip network as neighbors rather than :ANONYMOUS nodes, simply
because non-anonymous proxy nodes can have expectations set up for replies and thus not rely solely on timeouts.
Bottom line: Non-anonymous nodes are faster than anonymous ones.

This leads to another observation: Don't put :ANONYMOUS nodes into the neighbors slot of any node. That way,
you won't have to worry about :ANONYMOUS nodes being downstream, ever.

Furthermore, if node X passes along a direct-reply message (that is, its reply-to slot contains a UID), it must
never call #'prepare-repliers. This is pretty obvious at first glance, because in the case of direct replies,
node X is probably not going to be the replyee anyway. But what if it is? What if node X _is_ the replyee?
Even in that case, we can't always be sure that every downstream node is going to reply. If one of those
downstream nodes is an :ANONYMOUS node, it'll never reply (because anonymous nodes never masquerade as the source of
reply messages). And direct messages can be weird: Any given downstream node may or may not choose to even accept
the message, let alone reply to it. Direct messages are in some sense intended to be weird. They're for bootstrapping
or out-of-band status purposes or whatever. The point is, only :UPSTREAM solicitations should ever definitively
expect replies from specific downstream nodes, and even then, only in the case where there's no :ANONYMOUS node in
the downstream set.

A subtlety: Note that coalescence is a different issue than expectations. It's possible that a node will want to coalesce
its replies without having any expectations as to who will reply. This is precisely the case for node X, where node X
is expecting direct replies to itself. See generic-srr-handler method for solicitations for how this is coded.

NOTE E: Debugging Actor code
If it seems like -- contrary to all expectations -- messages are never getting delivered to a given actor,
check the processes window. If a given Actor Executive shows "Active" rather than "Waiting for Actor", that's
a HUGE red flag. It means some Actor's code body never exited. And that actor will appear to have stopped 
receiving messages.
In ccl, you can interrupt and backtrace a background process like so:
(ccl::force-break-in-listener (gossip::find-process <process-name>))

NOTE F: If you call (format *logstream* <etc>) and *logstream* is a 'highlevel-hemlock-output-stream (in CCL),
then either a lot of small strings or even a lot
of individual characters get written to the *logstream* and this is much too slow in CCL
because every output to *logstream* has to be done in the system's event loop.
Although this is CCL-specific, it doesn't hurt anything to pre-convert to a string using 
(format nil <etc>) on non-CCL platforms, so that's why we're doing it this way.

NOTE G: network messages are 5 pieces in a list:
destuid of ultimate receiving node
srcuid of sending node
remote-address of sender
remote-port of sender
gossip-msg

NOTE H: The uber-network, the uber-set and +default-graphid+

TODO:
Ensure that anonymous nodes can never be in a neighborhood.
Figure out a way to make solicit-direct work in that case.

|#
