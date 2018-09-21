(in-package :randhound)

(defun init-ordered-table ()
  "The rh leader's idea of the node network.
A table that should be in consistent sort order."
  (unless randhound::*node-table*
    (let ((node-table (emotiq/config:get-pkeys)))
      (unless node-table
        (error "Failed to find the node table"))
      (setf randhound::*node-table* node-table))))

(defun nodes ()
  ;;; TODO just create a simple in memory graph of Cosi nodes, bypassing Gossip
  ;;; gonna fail unless gossip is started
  (or
   (gossip:get-live-uids)
   (gossip:local-real-nodes)))





