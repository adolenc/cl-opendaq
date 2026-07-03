(ql:quickload :opendaq :silent t)

;;;; Finding components with search filters.
;;;;
;;;; The getter methods for a device's tree -- CHANNELS, SIGNALS, DEVICES,
;;;; FUNCTION-BLOCKS, and a folder's ITEMS -- all take an optional search filter.
;;;; A filter answers two questions about every component the search walks over:
;;;; "accept this one into the result?" and "descend into its children?".
;;;;
;;;; With no filter the getters return only the immediate, visible children, so
;;;; CHANNELS of the top-level device below finds nothing -- the channels live one
;;;; device deeper.  A SEARCH-FILTER/RECURSIVE wrapper makes the search descend.
;;;;
;;;; Filters compose by construction: SEARCH-FILTER/AND, SEARCH-FILTER/OR, and
;;;; SEARCH-FILTER/NOT take other filters as their arguments.  The RECURSIVE
;;;; wrapper must be the outermost one -- never nest it inside another filter.

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")
(defparameter *root* (daq:root-device *instance*))


(defun show (label components)
  "Print COMPONENTS by their local-id under LABEL."
  (format t "~A~%    => ~{~A~^, ~}~%~%"
          label
          (or (mapcar #'daq:local-id components) '("(none)"))))


;;; Give a couple of channels some tags, so the tag filter has something to match.
;;; (RefCh0 and RefCh1 come from the reference device unlabelled.)
(dolist (channel (daq:channels *root*
                               (make-instance 'daq:search-filter/recursive :filter (make-instance 'daq:search-filter/any))))
  (let ((tags (daq:as (daq:tags channel) 'daq:tags-private)))
    (daq:add tags "analog")
    (when (string= (daq:local-id channel) "RefCh0")
      (daq:add tags "primary"))))


(show "channels, no filter (immediate children only)"
      (daq:channels *root*))

(show "channels, recursive(any)"
      (daq:channels *root*
                    (make-instance 'daq:search-filter/recursive
                                   :filter (make-instance 'daq:search-filter/any))))

(show "channels, recursive(id = RefCh1)"
      (daq:channels *root*
                    (make-instance 'daq:search-filter/recursive
                                   :filter (make-instance 'daq:search-filter/local-id
                                                          :local-id "RefCh1"))))

(show "signals, recursive(id = AI0 OR id = AI1)"
      (daq:signals *root*
                   (make-instance 'daq:search-filter/recursive
                                  :filter (make-instance 'daq:search-filter/or
                                                         :left (make-instance 'daq:search-filter/local-id :local-id "AI0")
                                                         :right (make-instance 'daq:search-filter/local-id :local-id "AI1")))))

(show "channels, recursive(NOT id = RefCh1)"
      (daq:channels *root*
                    (make-instance 'daq:search-filter/recursive
                                   :filter (make-instance 'daq:search-filter/not
                                                          :filter (make-instance 'daq:search-filter/local-id :local-id "RefCh1")))))

(let ((tags (make-instance 'daq:object-list)))
  (daq:push-back tags "analog")
  (show "channels, recursive(tag = analog AND NOT id = RefCh1)"
        (daq:channels *root*
                      (make-instance 'daq:search-filter/recursive
                                     :filter (make-instance 'daq:search-filter/and
                                                            :left (make-instance 'daq:search-filter/required-tags :required-tags tags)
                                                            :right (make-instance 'daq:search-filter/not :filter (make-instance 'daq:search-filter/local-id :local-id "RefCh1")))))))
