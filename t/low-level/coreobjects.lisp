(in-package #:opendaq.tests)

;; Direct port of the currently supported upstream coreobjects coverage
;; that is expressible through the generated low-level Lisp bindings.
;; Ownable and PropertyObjectProtected remain blocked until the generator
;; supports daqBaseObject_borrowInterface and daqIntfID-by-value signatures.

(in-suite low-level-coreobjects-suite)

(defparameter *coreobjects-end-update-called* nil)

(cffi:defcallback %coreobjects-on-property-object-update-end :void
    ((sender opendaq.low-level::daq-base-object)
     (args opendaq.low-level::daq-base-object))
  (let ((properties nil))
    (unwind-protect
        (progn
          (setf properties (opendaq.low-level:end-update-event-args/get-properties args))
          (when (= 0 (opendaq.low-level:list/get-count properties))
            (setf *coreobjects-end-update-called* t)))
      (when (and properties (not (cffi:null-pointer-p properties)))
        (opendaq.low-level:base-object/release-ref properties))
      (opendaq.low-level:base-object/release-ref sender)
      (opendaq.low-level:base-object/release-ref args))))

(test coreobjects-argument-info
  (opendaq.low-level:with-daq-objects (arg-info name name-out)
    (setf name (opendaq.low-level:make-daq-string "test_argument"))
    (setf arg-info (opendaq.low-level:argument-info/create-argument-info name :int))
    (setf name-out (opendaq.low-level:argument-info/get-name arg-info))
    (is (string= "test_argument" (%daq-string-value name-out)) "coreobjects/ArgumentInfo name mismatch")
    (is (eq :int (opendaq.low-level:argument-info/get-type arg-info)) "coreobjects/ArgumentInfo type mismatch")))

(test coreobjects-authentication-provider
  (opendaq.low-level:with-daq-objects (username password-hash groups user user-list auth-provider user-out)
    (setf username (opendaq.low-level:make-daq-string "test_user"))
    (setf password-hash (opendaq.low-level:make-daq-string "test_hash"))
    (setf groups (opendaq.low-level:list/create-list))
    (setf user (opendaq.low-level:user/create-user username password-hash groups))
    (setf user-list (opendaq.low-level:list/create-list))
    (opendaq.low-level:list/push-back user-list user)
    (setf auth-provider
          (opendaq.low-level:authentication-provider/create-static-authentication-provider 1 user-list))

    (setf user-out (opendaq.low-level:authentication-provider/authenticate-anonymous auth-provider))
    (is (not (cffi:null-pointer-p user-out)) "coreobjects/AuthenticationProvider authenticate-anonymous returned null")
    (setf user-out nil)

    (setf user-out (opendaq.low-level:authentication-provider/authenticate auth-provider username password-hash))
    (is (not (cffi:null-pointer-p user-out)) "coreobjects/AuthenticationProvider authenticate returned null")
    (setf user-out nil)

    (setf user-out (opendaq.low-level:authentication-provider/find-user auth-provider username))
    (is (not (cffi:null-pointer-p user-out)) "coreobjects/AuthenticationProvider find-user returned null")))

(test coreobjects-callable-info
  (opendaq.low-level:with-daq-objects (argument-info-list name arg-info callable-info arguments)
    (setf argument-info-list (opendaq.low-level:list/create-list))
    (setf name (opendaq.low-level:make-daq-string "test_argument"))
    (setf arg-info (opendaq.low-level:argument-info/create-argument-info name :int))
    (opendaq.low-level:list/push-back argument-info-list arg-info)
    (setf callable-info
          (opendaq.low-level:callable-info/create-callable-info argument-info-list :int 1))
    (is (= 1 (opendaq.low-level:callable-info/is-const callable-info)) "coreobjects/CallableInfo const flag mismatch")
    (is (eq :int (opendaq.low-level:callable-info/get-return-type callable-info)) "coreobjects/CallableInfo return type mismatch")
    (setf arguments (opendaq.low-level:callable-info/get-arguments callable-info))
    (is (= 1 (opendaq.low-level:list/get-count arguments)) "coreobjects/CallableInfo arguments mismatch")))

(test coreobjects-coercer
  (opendaq.low-level:with-daq-objects (coercer eval-str value coerced-value)
    (setf eval-str (opendaq.low-level:make-daq-string "value + 2"))
    (setf coercer (opendaq.low-level:coercer/create-coercer eval-str))
    (setf value (opendaq.low-level:integer/create-integer 10))
    (setf coerced-value (opendaq.low-level:coercer/coerce coercer (cffi:null-pointer) value))
    (is (not (cffi:null-pointer-p coerced-value)) "coreobjects/Coercer returned null")
    (is (= 12 (opendaq.low-level:integer/get-value coerced-value)) "coreobjects/Coercer value mismatch")))

(test coreobjects-end-update-event-args
  (opendaq.low-level:with-daq-objects (prop-obj event handler)
    (setf *coreobjects-end-update-called* nil)
    (setf prop-obj (opendaq.low-level:property-object/create-property-object))
    (setf event (opendaq.low-level:property-object/get-on-end-update prop-obj))
    (setf handler
          (opendaq.low-level:event-handler/create-event-handler
           (cffi:callback %coreobjects-on-property-object-update-end)))
    (opendaq.low-level:event/add-handler event handler)
    (opendaq.low-level:property-object/begin-update prop-obj)
    (opendaq.low-level:property-object/end-update prop-obj)
    (is (not (null *coreobjects-end-update-called*)) "coreobjects/EndUpdateEventArgs callback was not invoked")))

(test coreobjects-eval-value
  (opendaq.low-level:with-daq-objects (prop-obj name default-value visible prop ref-name eval-str eval-value ref-prop value)
    (setf prop-obj (opendaq.low-level:property-object/create-property-object))
    (setf name (opendaq.low-level:make-daq-string "test_property"))
    (setf default-value (opendaq.low-level:integer/create-integer 10))
    (setf visible (opendaq.low-level:boolean/create-boolean 1))
    (setf prop (opendaq.low-level:property/create-int-property name default-value visible))
    (opendaq.low-level:property-object/add-property prop-obj prop)

    (setf ref-name (opendaq.low-level:make-daq-string "ref_property"))
    (setf eval-str (opendaq.low-level:make-daq-string "%test_property"))
    (setf eval-value (opendaq.low-level:eval-value/create-eval-value eval-str))
    (setf ref-prop (opendaq.low-level:property/create-reference-property ref-name eval-value))
    (opendaq.low-level:property-object/add-property prop-obj ref-prop)

    (setf value (opendaq.low-level:property-object/get-property-value prop-obj ref-name))
    (is (= 10 (opendaq.low-level:integer/get-value value)) "coreobjects/EvalValue value mismatch")))

(test coreobjects-property
  (opendaq.low-level:with-daq-objects (prop name default-value visible default-value-out name-out)
    (setf name (opendaq.low-level:make-daq-string "test_property"))
    (setf default-value (opendaq.low-level:integer/create-integer 10))
    (setf visible (opendaq.low-level:boolean/create-boolean 1))
    (setf prop (opendaq.low-level:property/create-int-property name default-value visible))
    (setf default-value-out (opendaq.low-level:property/get-default-value prop))
    (is (= 10 (opendaq.low-level:integer/get-value default-value-out)) "coreobjects/Property default value mismatch")
    (setf name-out (opendaq.low-level:property/get-name prop))
    (is (string= "test_property" (%daq-string-value name-out)) "coreobjects/Property name mismatch")
    (is (= 1 (opendaq.low-level:property/get-visible prop)) "coreobjects/Property visible mismatch")))

(test coreobjects-property-builder
  (opendaq.low-level:with-daq-objects (prop-builder name default-value visible property default-value-out name-out)
    (setf name (opendaq.low-level:make-daq-string "test_property"))
    (setf default-value (opendaq.low-level:integer/create-integer 10))
    (setf visible (opendaq.low-level:boolean/create-boolean 1))
    (setf prop-builder (opendaq.low-level:property-builder/create-int-property-builder name default-value))
    (opendaq.low-level:property-builder/set-visible prop-builder visible)
    (setf property (opendaq.low-level:property-builder/build prop-builder))
    (setf default-value-out (opendaq.low-level:property/get-default-value property))
    (is (= 10 (opendaq.low-level:integer/get-value default-value-out)) "coreobjects/PropertyBuilder default value mismatch")
    (setf name-out (opendaq.low-level:property/get-name property))
    (is (string= "test_property" (%daq-string-value name-out)) "coreobjects/PropertyBuilder name mismatch")
    (is (= 1 (opendaq.low-level:property/get-visible property)) "coreobjects/PropertyBuilder visible mismatch")))

(test coreobjects-property-object
  (opendaq.low-level:with-daq-objects (prop-obj prop name default-value visible prop-out)
    (setf prop-obj (opendaq.low-level:property-object/create-property-object))
    (setf name (opendaq.low-level:make-daq-string "test_property"))
    (setf default-value (opendaq.low-level:integer/create-integer 10))
    (setf visible (opendaq.low-level:boolean/create-boolean 1))
    (setf prop (opendaq.low-level:property/create-int-property name default-value visible))
    (opendaq.low-level:property-object/add-property prop-obj prop)
    (setf prop-out (opendaq.low-level:property-object/get-property prop-obj name))
    (is (= 1 (opendaq.low-level:base-object/equals prop prop-out)) "coreobjects/PropertyObject property mismatch")
    (is (= 1 (opendaq.low-level:property-object/has-property prop-obj name)) "coreobjects/PropertyObject expected property before removal")
    (opendaq.low-level:property-object/remove-property prop-obj name)
    (is (= 0 (opendaq.low-level:property-object/has-property prop-obj name)) "coreobjects/PropertyObject expected property removal")))

(test coreobjects-property-object-class
  (opendaq.low-level:with-daq-objects (prop-obj-class builder name prop prop-name default-value visible prop-out)
    (setf name (opendaq.low-level:make-daq-string "test_property_class"))
    (setf builder (opendaq.low-level:property-object-class-builder/create-property-object-class-builder name))
    (setf prop-name (opendaq.low-level:make-daq-string "test_property"))
    (setf default-value (opendaq.low-level:integer/create-integer 10))
    (setf visible (opendaq.low-level:boolean/create-boolean 1))
    (setf prop (opendaq.low-level:property/create-int-property prop-name default-value visible))
    (opendaq.low-level:property-object-class-builder/add-property builder prop)
    (setf prop-obj-class (opendaq.low-level:property-object-class-builder/build builder))
    (setf prop-out (opendaq.low-level:property-object-class/get-property prop-obj-class prop-name))
    (is (= 1 (opendaq.low-level:base-object/equals prop prop-out)) "coreobjects/PropertyObjectClass property mismatch")))

(test coreobjects-property-value-event-args
  (opendaq.low-level:with-daq-objects (event-args prop name default-value visible value1 value2 value-out)
    (setf name (opendaq.low-level:make-daq-string "test_property"))
    (setf default-value (opendaq.low-level:integer/create-integer 10))
    (setf visible (opendaq.low-level:boolean/create-boolean 1))
    (setf prop (opendaq.low-level:property/create-int-property name default-value visible))
    (setf value1 (opendaq.low-level:integer/create-integer 20))
    (setf value2 (opendaq.low-level:integer/create-integer 30))
    (setf event-args
          (opendaq.low-level:property-value-event-args/create-property-value-event-args
           prop
           value2
           value1
           :update
           0))
    (setf value-out (opendaq.low-level:property-value-event-args/get-value event-args))
    (is (= 1 (opendaq.low-level:base-object/equals value-out value2)) "coreobjects/PropertyValueEventArgs value mismatch")
    (setf value-out nil)
    (setf value-out (opendaq.low-level:property-value-event-args/get-old-value event-args))
    (is (= 1 (opendaq.low-level:base-object/equals value-out value1)) "coreobjects/PropertyValueEventArgs old value mismatch")))

(test coreobjects-unit
  (opendaq.low-level:with-daq-objects (unit-builder name symbol unit name-out symbol-out)
    (setf name (opendaq.low-level:make-daq-string "test_unit"))
    (setf symbol (opendaq.low-level:make-daq-string "tu"))
    (setf unit-builder (opendaq.low-level:unit-builder/create-unit-builder))
    (opendaq.low-level:unit-builder/set-name unit-builder name)
    (opendaq.low-level:unit-builder/set-symbol unit-builder symbol)
    (setf unit (opendaq.low-level:unit-builder/build unit-builder))
    (setf name-out (opendaq.low-level:unit/get-name unit))
    (setf symbol-out (opendaq.low-level:unit/get-symbol unit))
    (is (string= "test_unit" (%daq-string-value name-out)) "coreobjects/Unit name mismatch")
    (is (string= "tu" (%daq-string-value symbol-out)) "coreobjects/Unit symbol mismatch")))

(test coreobjects-user
  (opendaq.low-level:with-daq-objects (username password-hash groups user username-out)
    (setf username (opendaq.low-level:make-daq-string "test_user"))
    (setf password-hash (opendaq.low-level:make-daq-string "test_hash"))
    (setf groups (opendaq.low-level:list/create-list))
    (setf user (opendaq.low-level:user/create-user username password-hash groups))
    (setf username-out (opendaq.low-level:user/get-username user))
    (is (string= "test_user" (%daq-string-value username-out)) "coreobjects/User username mismatch")))

(test coreobjects-validator
  (opendaq.low-level:with-daq-objects (validator eval-str value invalid-value)
    (setf eval-str (opendaq.low-level:make-daq-string "value > 5"))
    (setf validator (opendaq.low-level:validator/create-validator eval-str))
    (setf value (opendaq.low-level:integer/create-integer 10))
    (opendaq.low-level:validator/validate validator (cffi:null-pointer) value)
    (setf invalid-value (opendaq.low-level:integer/create-integer 3))
    (let ((saw-error nil))
      (handler-case
          (opendaq.low-level:validator/validate validator (cffi:null-pointer) invalid-value)
        (daq:opendaq-error ()
          (setf saw-error t)))
      (opendaq.low-level::clear-error-info)
      (is (not (null saw-error)) "coreobjects/Validator expected validation error for invalid value"))))
