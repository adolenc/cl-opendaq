(ql:quickload :opendaq :silent t)

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")

(defun type-label (component)
  "Readable type name for COMPONENT, e.g. \"Channel\" or \"FunctionBlock\"."
  (remove #\- (string-capitalize (symbol-name
                                   (or (daq:component-type component) 'component)))))

(defun type-name (value-type)
  "Readable name for a property's core type, e.g. :DAQ-CT-INT => \"Int\"."
  (let ((s (symbol-name value-type)))
    (remove #\- (string-capitalize
                  (if (eql 0 (search "DAQ-CT-" s))
                      (subseq s 7)
                      s)))))

(defun property-value-string (property-object property)
  "Printable value of PROPERTY on PROPERTY-OBJECT.  Scalar values are unboxed to
their native Lisp value; structured ones are shown as \"<Type>\"."
  (let ((class (daq:core-type->class (daq:value-type property))))
    (if class
        (format nil "~S" (daq:unbox (daq:as (daq:property-value property-object (daq:name property)) class)))
        (format nil "<~A>" (type-name (daq:value-type property))))))

(defun draw-properties (component prefix)
  "Print the visible properties of COMPONENT, each line indented with PREFIX."
  (when (daq:is-p component 'daq:property-object)
    (let ((object (daq:as component 'daq:property-object)))
      (dolist (property (daq:visible-properties object))
        (format t "~A• ~A : ~A = ~A~%"
                prefix
                (daq:name property)
                (type-name (daq:value-type property))
                (property-value-string object property))))))

(defun children (component)
  "The immediate child components of COMPONENT if it is a folder, else NIL."
  (when (daq:is-p component 'daq:folder)
    (daq:items (daq:as component 'daq:folder) nil)))

(defun draw-children (component prefix)
  (let* ((kids (children component))
         (n (length kids)))
    (loop for child in kids
          for i from 1
          for last = (= i n)
          for child-prefix = (concatenate 'string prefix (if last "   " "│  "))
          do (format t "~A~A~A : ~A (~A)~%"
                     prefix
                     (if last "└─ " "├─ ")
                     (daq:name child)
                     (type-label child)
                     (daq:local-id child))
             (draw-properties child child-prefix)
             (draw-children child child-prefix))))

(let ((root (daq:root-device *instance*)))
  (format t "~A : ~A (~A)~%" (daq:name root) (type-label root) (daq:local-id root))
  (draw-properties root "")
  (draw-children root ""))
