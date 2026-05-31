(in-package #:opendaq.tests)

;; Direct port of the currently supported upstream coreobjects coverage
;; that is expressible through the generated low-level Lisp bindings.
;; Ownable and PropertyObjectProtected remain blocked until the generator
;; supports daqBaseObject_borrowInterface and daqIntfID-by-value signatures.

(in-suite coreobjects-suite)

(defparameter *coreobjects-end-update-called* nil)

(cffi:defcallback %coreobjects-on-property-object-update-end :void
    ((sender daq::daq-base-object)
     (args daq::daq-base-object))
  (let ((properties nil))
    (unwind-protect
        (progn
          (setf properties (daq:end-update-event-args/get-properties args))
          (when (= 0 (daq:list/get-count properties))
            (setf *coreobjects-end-update-called* t)))
      (when (and properties (not (cffi:null-pointer-p properties)))
        (daq:base-object/release-ref properties))
      (daq:base-object/release-ref sender)
      (daq:base-object/release-ref args))))

(test coreobjects-argument-info
  (daq:with-daq-objects (arg-info name name-out)
    (setf name (daq:make-daq-string "test_argument"))
    (setf arg-info (daq:argument-info/create-argument-info name :daq-ct-int))
    (setf name-out (daq:argument-info/get-name arg-info))
    (is (string= "test_argument" (%daq-string-value name-out))
        "coreobjects/ArgumentInfo name mismatch")
    (is (eq :daq-ct-int (daq:argument-info/get-type arg-info))
        "coreobjects/ArgumentInfo type mismatch")))

(test coreobjects-authentication-provider
  (daq:with-daq-objects (username password-hash groups user user-list auth-provider user-out)
    (setf username (daq:make-daq-string "test_user"))
    (setf password-hash (daq:make-daq-string "test_hash"))
    (setf groups (daq:list/create-list))
    (setf user (daq:user/create-user username password-hash groups))
    (setf user-list (daq:list/create-list))
    (daq:list/push-back user-list user)
    (setf auth-provider
          (daq:authentication-provider/create-static-authentication-provider 1 user-list))

    (setf user-out (daq:authentication-provider/authenticate-anonymous auth-provider))
    (is (not (cffi:null-pointer-p user-out))
        "coreobjects/AuthenticationProvider authenticate-anonymous returned null")
    (setf user-out nil)

    (setf user-out (daq:authentication-provider/authenticate auth-provider username password-hash))
    (is (not (cffi:null-pointer-p user-out))
        "coreobjects/AuthenticationProvider authenticate returned null")
    (setf user-out nil)

    (setf user-out (daq:authentication-provider/find-user auth-provider username))
    (is (not (cffi:null-pointer-p user-out))
        "coreobjects/AuthenticationProvider find-user returned null")))

(test coreobjects-callable-info
  (daq:with-daq-objects (argument-info-list name arg-info callable-info arguments)
    (setf argument-info-list (daq:list/create-list))
    (setf name (daq:make-daq-string "test_argument"))
    (setf arg-info (daq:argument-info/create-argument-info name :daq-ct-int))
    (daq:list/push-back argument-info-list arg-info)
    (setf callable-info
          (daq:callable-info/create-callable-info argument-info-list :daq-ct-int 1))
    (is (= 1 (daq:callable-info/is-const callable-info))
        "coreobjects/CallableInfo const flag mismatch")
    (is (eq :daq-ct-int (daq:callable-info/get-return-type callable-info))
        "coreobjects/CallableInfo return type mismatch")
    (setf arguments (daq:callable-info/get-arguments callable-info))
    (is (= 1 (daq:list/get-count arguments))
        "coreobjects/CallableInfo arguments mismatch")))

(test coreobjects-coercer
  (daq:with-daq-objects (coercer eval-str value coerced-value)
    (setf eval-str (daq:make-daq-string "value + 2"))
    (setf coercer (daq:coercer/create-coercer eval-str))
    (setf value (daq:integer/create-integer 10))
    (setf coerced-value (daq:coercer/coerce coercer (cffi:null-pointer) value))
    (is (not (cffi:null-pointer-p coerced-value))
        "coreobjects/Coercer returned null")
    (is (= 12 (daq:integer/get-value coerced-value))
        "coreobjects/Coercer value mismatch")))

(test coreobjects-end-update-event-args
  (daq:with-daq-objects (prop-obj event handler)
    (setf *coreobjects-end-update-called* nil)
    (setf prop-obj (daq:property-object/create-property-object))
    (setf event (daq:property-object/get-on-end-update prop-obj))
    (setf handler
          (daq:event-handler/create-event-handler
           (cffi:callback %coreobjects-on-property-object-update-end)))
    (daq:event/add-handler event handler)
    (daq:property-object/begin-update prop-obj)
    (daq:property-object/end-update prop-obj)
    (is (not (null *coreobjects-end-update-called*))
        "coreobjects/EndUpdateEventArgs callback was not invoked")))

(test coreobjects-eval-value
  (daq:with-daq-objects (prop-obj name default-value visible prop ref-name eval-str eval-value ref-prop value)
    (setf prop-obj (daq:property-object/create-property-object))
    (setf name (daq:make-daq-string "test_property"))
    (setf default-value (daq:integer/create-integer 10))
    (setf visible (daq:boolean/create-boolean 1))
    (setf prop (daq:property/create-int-property name default-value visible))
    (daq:property-object/add-property prop-obj prop)

    (setf ref-name (daq:make-daq-string "ref_property"))
    (setf eval-str (daq:make-daq-string "%test_property"))
    (setf eval-value (daq:eval-value/create-eval-value eval-str))
    (setf ref-prop (daq:property/create-reference-property ref-name eval-value))
    (daq:property-object/add-property prop-obj ref-prop)

    (setf value (daq:property-object/get-property-value prop-obj ref-name))
    (is (= 10 (daq:integer/get-value value))
        "coreobjects/EvalValue value mismatch")))

(test coreobjects-permissions
  (daq:with-daq-objects (admin-groups guest-groups admin-name guest-name password admin guest
                         manager mask-builder permissions-builder admin-permissions)
    (setf admin-groups (daq:list/create-list))
    (setf guest-groups (daq:list/create-list))
    (setf admin-name (daq:make-daq-string "admin"))
    (setf guest-name (daq:make-daq-string "guest"))
    (setf password (daq:make-daq-string "password"))

    (daq:list/push-back admin-groups admin-name)
    (daq:list/push-back admin-groups guest-name)
    (daq:list/push-back guest-groups guest-name)

    (setf admin (daq:user/create-user admin-name password admin-groups))
    (setf guest (daq:user/create-user guest-name password guest-groups))
    (setf manager (daq:permission-manager/create-permission-manager (cffi:null-pointer)))
    (setf mask-builder (daq:permission-mask-builder/create-permission-mask-builder))
    (daq:permission-mask-builder/read mask-builder)
    (daq:permission-mask-builder/write mask-builder)

    (setf permissions-builder (daq:permissions-builder/create-permissions-builder))
    (daq:permissions-builder/assign permissions-builder admin-name mask-builder)
    (setf admin-permissions (daq:permissions-builder/build permissions-builder))
    (daq:permission-manager/set-permissions manager admin-permissions)

    (is (= 1 (daq:permission-manager/is-authorized manager admin :daq-permission-read))
        "coreobjects/Permissions admin read mismatch")
    (is (= 1 (daq:permission-manager/is-authorized manager admin :daq-permission-write))
        "coreobjects/Permissions admin write mismatch")
    (is (= 0 (daq:permission-manager/is-authorized manager admin :daq-permission-execute))
        "coreobjects/Permissions admin execute mismatch")
    (is (= 0 (daq:permission-manager/is-authorized manager guest :daq-permission-read))
        "coreobjects/Permissions guest read mismatch")
    (is (= 0 (daq:permission-manager/is-authorized manager guest :daq-permission-write))
        "coreobjects/Permissions guest write mismatch")
    (is (= 0 (daq:permission-manager/is-authorized manager guest :daq-permission-execute))
        "coreobjects/Permissions guest execute mismatch")))

(test coreobjects-property
  (daq:with-daq-objects (prop name default-value visible default-value-out name-out)
    (setf name (daq:make-daq-string "test_property"))
    (setf default-value (daq:integer/create-integer 10))
    (setf visible (daq:boolean/create-boolean 1))
    (setf prop (daq:property/create-int-property name default-value visible))
    (setf default-value-out (daq:property/get-default-value prop))
    (is (= 10 (daq:integer/get-value default-value-out))
        "coreobjects/Property default value mismatch")
    (setf name-out (daq:property/get-name prop))
    (is (string= "test_property" (%daq-string-value name-out))
        "coreobjects/Property name mismatch")
    (is (= 1 (daq:property/get-visible prop))
        "coreobjects/Property visible mismatch")))

(test coreobjects-property-builder
  (daq:with-daq-objects (prop-builder name default-value visible property default-value-out name-out)
    (setf name (daq:make-daq-string "test_property"))
    (setf default-value (daq:integer/create-integer 10))
    (setf visible (daq:boolean/create-boolean 1))
    (setf prop-builder (daq:property-builder/create-int-property-builder name default-value))
    (daq:property-builder/set-visible prop-builder visible)
    (setf property (daq:property-builder/build prop-builder))
    (setf default-value-out (daq:property/get-default-value property))
    (is (= 10 (daq:integer/get-value default-value-out))
        "coreobjects/PropertyBuilder default value mismatch")
    (setf name-out (daq:property/get-name property))
    (is (string= "test_property" (%daq-string-value name-out))
        "coreobjects/PropertyBuilder name mismatch")
    (is (= 1 (daq:property/get-visible property))
        "coreobjects/PropertyBuilder visible mismatch")))

(test coreobjects-property-object
  (daq:with-daq-objects (prop-obj prop name default-value visible prop-out)
    (setf prop-obj (daq:property-object/create-property-object))
    (setf name (daq:make-daq-string "test_property"))
    (setf default-value (daq:integer/create-integer 10))
    (setf visible (daq:boolean/create-boolean 1))
    (setf prop (daq:property/create-int-property name default-value visible))
    (daq:property-object/add-property prop-obj prop)
    (setf prop-out (daq:property-object/get-property prop-obj name))
    (is (= 1 (daq:base-object/equals prop prop-out))
        "coreobjects/PropertyObject property mismatch")
    (is (= 1 (daq:property-object/has-property prop-obj name))
        "coreobjects/PropertyObject expected property before removal")
    (daq:property-object/remove-property prop-obj name)
    (is (= 0 (daq:property-object/has-property prop-obj name))
        "coreobjects/PropertyObject expected property removal")))

(test coreobjects-property-object-class
  (daq:with-daq-objects (prop-obj-class builder name prop prop-name default-value visible prop-out)
    (setf name (daq:make-daq-string "test_property_class"))
    (setf builder (daq:property-object-class-builder/create-property-object-class-builder name))
    (setf prop-name (daq:make-daq-string "test_property"))
    (setf default-value (daq:integer/create-integer 10))
    (setf visible (daq:boolean/create-boolean 1))
    (setf prop (daq:property/create-int-property prop-name default-value visible))
    (daq:property-object-class-builder/add-property builder prop)
    (setf prop-obj-class (daq:property-object-class-builder/build builder))
    (setf prop-out (daq:property-object-class/get-property prop-obj-class prop-name))
    (is (= 1 (daq:base-object/equals prop prop-out))
        "coreobjects/PropertyObjectClass property mismatch")))

(test coreobjects-property-value-event-args
  (daq:with-daq-objects (event-args prop name default-value visible value1 value2 value-out)
    (setf name (daq:make-daq-string "test_property"))
    (setf default-value (daq:integer/create-integer 10))
    (setf visible (daq:boolean/create-boolean 1))
    (setf prop (daq:property/create-int-property name default-value visible))
    (setf value1 (daq:integer/create-integer 20))
    (setf value2 (daq:integer/create-integer 30))
    (setf event-args
          (daq:property-value-event-args/create-property-value-event-args
           prop
           value2
           value1
           :daq-property-event-type-event-type-update
           0))
    (setf value-out (daq:property-value-event-args/get-value event-args))
    (is (= 1 (daq:base-object/equals value-out value2))
        "coreobjects/PropertyValueEventArgs value mismatch")
    (setf value-out nil)
    (setf value-out (daq:property-value-event-args/get-old-value event-args))
    (is (= 1 (daq:base-object/equals value-out value1))
        "coreobjects/PropertyValueEventArgs old value mismatch")))

(test coreobjects-unit
  (daq:with-daq-objects (unit-builder name symbol unit name-out symbol-out)
    (setf name (daq:make-daq-string "test_unit"))
    (setf symbol (daq:make-daq-string "tu"))
    (setf unit-builder (daq:unit-builder/create-unit-builder))
    (daq:unit-builder/set-name unit-builder name)
    (daq:unit-builder/set-symbol unit-builder symbol)
    (setf unit (daq:unit-builder/build unit-builder))
    (setf name-out (daq:unit/get-name unit))
    (setf symbol-out (daq:unit/get-symbol unit))
    (is (string= "test_unit" (%daq-string-value name-out))
        "coreobjects/Unit name mismatch")
    (is (string= "tu" (%daq-string-value symbol-out))
        "coreobjects/Unit symbol mismatch")))

(test coreobjects-user
  (daq:with-daq-objects (username password-hash groups user username-out)
    (setf username (daq:make-daq-string "test_user"))
    (setf password-hash (daq:make-daq-string "test_hash"))
    (setf groups (daq:list/create-list))
    (setf user (daq:user/create-user username password-hash groups))
    (setf username-out (daq:user/get-username user))
    (is (string= "test_user" (%daq-string-value username-out))
        "coreobjects/User username mismatch")))

(test coreobjects-validator
  (daq:with-daq-objects (validator eval-str value invalid-value)
    (setf eval-str (daq:make-daq-string "value > 5"))
    (setf validator (daq:validator/create-validator eval-str))
    (setf value (daq:integer/create-integer 10))
    (daq:validator/validate validator (cffi:null-pointer) value)
    (setf invalid-value (daq:integer/create-integer 3))
    (let ((saw-error nil))
      (handler-case
          (daq:validator/validate validator (cffi:null-pointer) invalid-value)
        (daq:opendaq-error ()
          (setf saw-error t)))
      (daq:clear-error-info)
      (is (not (null saw-error))
          "coreobjects/Validator expected validation error for invalid value"))))
