(in-package #:opendaq.tests)

(in-suite high-level-coreobjects-suite)

(defparameter *high-level-coreobjects-update-ended* nil)

(cffi:defcallback %high-level-coreobjects-on-property-object-update-end :void
    ((sender opendaq.low-level::daq-base-object)
     (args opendaq.low-level::daq-base-object))
  (let ((properties (opendaq.low-level:end-update-event-args/get-properties args)))
    (setf *high-level-coreobjects-update-ended* t)
    (opendaq.low-level:base-object/release-ref properties)
    (opendaq.low-level:base-object/release-ref sender)
    (opendaq.low-level:base-object/release-ref args)))

(test high-level-coreobjects-argument-and-callable-info
  (let* ((argument-info (make-instance 'daq:argument-info :name "test_argument" :type :daq-ct-int))
         (arguments (make-instance 'daq:object-list)))
    (daq:push-back arguments argument-info)
    (let ((callable-info (make-instance 'daq:callable-info
                                        :argument-info arguments
                                        :return-type :daq-ct-int
                                        :const-flag t)))
      (is (string= "test_argument" (daq:name argument-info))
          "High-level argument info wrappers should expose their name.")
      (is (eql :daq-ct-int (daq:argument-info-type argument-info))
          "High-level argument info wrappers should expose their core type.")
      (is (= 1 (list-length (daq:arguments callable-info)))
          "High-level callable-info wrappers should preserve their argument list.")
      (is (eql :daq-ct-int (daq:return-type callable-info))
          "High-level callable-info wrappers should expose their return type.")
      (is (daq:is-const callable-info)
          "High-level callable-info wrappers should preserve the const flag."))))

(test high-level-coreobjects-authentication-provider
  (let ((groups (make-instance 'daq:object-list)))
    (daq:push-back groups "guest")
    (let* ((user (make-instance 'daq:user
                                :username "test_user"
                                :password-hash "test_hash"
                                :groups groups))
           (users (make-instance 'daq:object-list)))
      (daq:push-back users user)
      (let* ((authentication-provider
               (daq:authentication-provider-create-static-authentication-provider t users))
             (anonymous-user (daq:authenticate-anonymous authentication-provider))
             (authenticated-user (daq:authenticate authentication-provider "test_user" "test_hash"))
             (found-user (daq:find-user authentication-provider "test_user"))
             (user-groups (daq:groups user)))
        (is (string= "test_user" (daq:username user))
            "High-level user wrappers should expose their username.")
        (is (listp user-groups)
            "High-level user wrappers should expose their groups as a Lisp list.")
        (is (typep anonymous-user 'daq:user)
            "High-level authentication providers should synthesize an anonymous user when enabled.")
        (is (string= "test_user" (daq:username authenticated-user))
            "High-level authentication providers should authenticate known users.")
        (is (string= "test_user" (daq:username found-user))
            "High-level authentication providers should resolve users by name.")))))

(test high-level-coreobjects-property-builders
  (let* ((default-value (make-instance 'daq:daq-integer :value 10))
         (visible-flag (make-instance 'daq:daq-boolean :value t))
         (property (daq:property-create-int-property "test_property" default-value visible-flag))
         (property-builder (daq:property-builder-create-int-property-builder "test_property" default-value)))
    (setf (daq:visible property-builder) visible-flag)
    (let* ((built-property (daq:build property-builder))
           (built-default (daq:default-value built-property))
           (property-object (make-instance 'daq:property-object))
           (property-class-builder (make-instance 'daq:property-object-class-builder :name "test_property_class")))
      (daq:add-property property-object property)
      (daq:add-property property-class-builder property)
      (let* ((property-object-property (daq:property-object-property property-object "test_property"))
             (property-default (daq:default-value property-object-property))
             (property-class (daq:build property-class-builder))
             (class-property (daq:property-object-class-property property-class "test_property")))
        (is (string= "test_property" (daq:name property))
            "High-level property factories should preserve the property name.")
        (is (= 10 (%boxed-integer-value built-default))
            "High-level property builders should preserve their default value.")
        (is (daq:visible built-property)
            "High-level built properties should expose their visibility as a Lisp boolean.")
        (is (daq:has-property property-object "test_property")
            "High-level property objects should contain added properties.")
        (is (= 10 (%boxed-integer-value property-default))
            "High-level property objects should expose the property's boxed default value.")
        (is (daq:has-property property-class "test_property")
            "High-level property-object-class builders should contain added properties.")
        (is (string= "test_property" (daq:name class-property))
            "High-level property-object classes should expose their class property by name.")
        (daq:remove-property property-object "test_property")
        (is (not (daq:has-property property-object "test_property"))
            "High-level property objects should remove properties through the generated API.")))))

(test high-level-coreobjects-eval-coercer-validator
  (let* ((property-object (make-instance 'daq:property-object))
         (default-value (make-instance 'daq:daq-integer :value 10))
         (visible-flag (make-instance 'daq:daq-boolean :value t))
         (property (daq:property-create-int-property "test_property" default-value visible-flag))
         (coercer (make-instance 'daq:coercer :eval "value + 2"))
         (validator (make-instance 'daq:validator :eval "value > 5")))
    (daq:add-property property-object property)
    (let ((eval-value (make-instance 'daq:eval-value :eval "%test_property")))
      (daq:add-property property-object
                        (daq:property-create-reference-property "ref_property" eval-value))
      (let* ((valid-value (make-instance 'daq:daq-integer :value 10))
             (invalid-value (make-instance 'daq:daq-integer :value 5))
             (reference-property (daq:property-value property-object "ref_property"))
             (coerced-value (daq:coerce coercer property-object valid-value)))
        (is (= 10 (%boxed-integer-value reference-property))
            "High-level eval-value references should resolve through property-object/property-value.")
        (is (string= "value + 2" (daq:eval coercer))
            "High-level coercers should expose their configured expression.")
        (is (= 12 (%boxed-integer-value coerced-value))
            "High-level coercers should transform the boxed value through the generated API.")
        (finishes
          (daq:validate validator property-object valid-value)
          "High-level validators should accept values that satisfy the expression.")
        (handler-case
            (progn
              (daq:validate validator property-object invalid-value)
              (fail "High-level validators should reject invalid values."))
          (daq:opendaq-error ()
            (pass "High-level validators should signal an openDAQ error for invalid values.")))))))

(test high-level-coreobjects-property-value-event-args
  (let* ((default-value (make-instance 'daq:daq-integer :value 10))
         (visible-flag (make-instance 'daq:daq-boolean :value t))
         (property (daq:property-create-int-property "test_property" default-value visible-flag))
         (old-value (make-instance 'daq:daq-integer :value 20))
         (new-value (make-instance 'daq:daq-integer :value 30))
         (event-args (make-instance 'daq:property-value-event-args
                                    :prop property
                                    :value new-value
                                    :old-value old-value
                                    :type :daq-property-event-type-event-type-update
                                    :is-updating nil))
         (event-value (daq:value event-args))
         (event-old-value (daq:old-value event-args)))
    (is (string= "test_property"
                 (daq:name (daq:property-value-event-args-property event-args)))
        "High-level property-value-event-args should expose their property.")
    (is (= 30 (%boxed-integer-value event-value))
        "High-level property-value-event-args should expose the new boxed value.")
    (is (= 20 (%boxed-integer-value event-old-value))
        "High-level property-value-event-args should expose the previous boxed value.")
    (is (eql :daq-property-event-type-event-type-update (daq:property-event-type event-args))
        "High-level property-value-event-args should preserve the event type symbol.")
    (is (null (daq:is-updating event-args))
        "High-level property-value-event-args should decode false updating flags into NIL.")))

(test high-level-coreobjects-end-update-event
  (let* ((property-object (make-instance 'daq:property-object))
         (event (daq:on-end-update property-object))
         (handler (make-instance 'daq:event-handler
                                 :call (cffi:callback %high-level-coreobjects-on-property-object-update-end))))
    (setf *high-level-coreobjects-update-ended* nil)
    (daq:add-handler event handler)
    (daq:begin-update property-object)
    (daq:end-update property-object)
    (is (not (null *high-level-coreobjects-update-ended*))
        "High-level property objects should emit the end-update event through the generated API.")))
