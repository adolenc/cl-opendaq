(in-package #:opendaq.tests)

;; Direct port of the currently supported upstream coreobjects coverage
;; that is expressible through the generated low-level Lisp bindings.
;; Ownable and PropertyObjectProtected remain blocked until the generator
;; supports daqBaseObject_borrowInterface and daqIntfID-by-value signatures.

(in-suite coreobjects-suite)

(defparameter *coreobjects-end-update-called* nil)

(cffi:defcallback %coreobjects-on-property-object-update-end :void
    ((sender daq.ll::daq-base-object)
     (args daq.ll::daq-base-object))
  (let ((properties nil))
    (unwind-protect
        (progn
          (setf properties (daq.ll:end-update-event-args/get-properties args))
          (when (= 0 (daq.ll:list/get-count properties))
            (setf *coreobjects-end-update-called* t)))
      (when (and properties (not (cffi:null-pointer-p properties)))
        (daq.ll:base-object/release-ref properties))
      (daq.ll:base-object/release-ref sender)
      (daq.ll:base-object/release-ref args))))

(test coreobjects-argument-info
  (daq.ll:with-daq-objects (arg-info name name-out)
    (setf name (daq.ll:make-daq-string "test_argument"))
    (setf arg-info (daq.ll:argument-info/create-argument-info name :daq-ct-int))
    (setf name-out (daq.ll:argument-info/get-name arg-info))
    (is (string= "test_argument" (%daq-string-value name-out))
        "coreobjects/ArgumentInfo name mismatch")
    (is (eq :daq-ct-int (daq.ll:argument-info/get-type arg-info))
        "coreobjects/ArgumentInfo type mismatch")))

(test coreobjects-authentication-provider
  (daq.ll:with-daq-objects (username password-hash groups user user-list auth-provider user-out)
    (setf username (daq.ll:make-daq-string "test_user"))
    (setf password-hash (daq.ll:make-daq-string "test_hash"))
    (setf groups (daq.ll:list/create-list))
    (setf user (daq.ll:user/create-user username password-hash groups))
    (setf user-list (daq.ll:list/create-list))
    (daq.ll:list/push-back user-list user)
    (setf auth-provider
          (daq.ll:authentication-provider/create-static-authentication-provider 1 user-list))

    (setf user-out (daq.ll:authentication-provider/authenticate-anonymous auth-provider))
    (is (not (cffi:null-pointer-p user-out))
        "coreobjects/AuthenticationProvider authenticate-anonymous returned null")
    (setf user-out nil)

    (setf user-out (daq.ll:authentication-provider/authenticate auth-provider username password-hash))
    (is (not (cffi:null-pointer-p user-out))
        "coreobjects/AuthenticationProvider authenticate returned null")
    (setf user-out nil)

    (setf user-out (daq.ll:authentication-provider/find-user auth-provider username))
    (is (not (cffi:null-pointer-p user-out))
        "coreobjects/AuthenticationProvider find-user returned null")))

(test coreobjects-callable-info
  (daq.ll:with-daq-objects (argument-info-list name arg-info callable-info arguments)
    (setf argument-info-list (daq.ll:list/create-list))
    (setf name (daq.ll:make-daq-string "test_argument"))
    (setf arg-info (daq.ll:argument-info/create-argument-info name :daq-ct-int))
    (daq.ll:list/push-back argument-info-list arg-info)
    (setf callable-info
          (daq.ll:callable-info/create-callable-info argument-info-list :daq-ct-int 1))
    (is (= 1 (daq.ll:callable-info/is-const callable-info))
        "coreobjects/CallableInfo const flag mismatch")
    (is (eq :daq-ct-int (daq.ll:callable-info/get-return-type callable-info))
        "coreobjects/CallableInfo return type mismatch")
    (setf arguments (daq.ll:callable-info/get-arguments callable-info))
    (is (= 1 (daq.ll:list/get-count arguments))
        "coreobjects/CallableInfo arguments mismatch")))

(test coreobjects-coercer
  (daq.ll:with-daq-objects (coercer eval-str value coerced-value)
    (setf eval-str (daq.ll:make-daq-string "value + 2"))
    (setf coercer (daq.ll:coercer/create-coercer eval-str))
    (setf value (daq.ll:integer/create-integer 10))
    (setf coerced-value (daq.ll:coercer/coerce coercer (cffi:null-pointer) value))
    (is (not (cffi:null-pointer-p coerced-value))
        "coreobjects/Coercer returned null")
    (is (= 12 (daq.ll:integer/get-value coerced-value))
        "coreobjects/Coercer value mismatch")))

(test coreobjects-end-update-event-args
  (daq.ll:with-daq-objects (prop-obj event handler)
    (setf *coreobjects-end-update-called* nil)
    (setf prop-obj (daq.ll:property-object/create-property-object))
    (setf event (daq.ll:property-object/get-on-end-update prop-obj))
    (setf handler
          (daq.ll:event-handler/create-event-handler
           (cffi:callback %coreobjects-on-property-object-update-end)))
    (daq.ll:event/add-handler event handler)
    (daq.ll:property-object/begin-update prop-obj)
    (daq.ll:property-object/end-update prop-obj)
    (is (not (null *coreobjects-end-update-called*))
        "coreobjects/EndUpdateEventArgs callback was not invoked")))

(test coreobjects-eval-value
  (daq.ll:with-daq-objects (prop-obj name default-value visible prop ref-name eval-str eval-value ref-prop value)
    (setf prop-obj (daq.ll:property-object/create-property-object))
    (setf name (daq.ll:make-daq-string "test_property"))
    (setf default-value (daq.ll:integer/create-integer 10))
    (setf visible (daq.ll:boolean/create-boolean 1))
    (setf prop (daq.ll:property/create-int-property name default-value visible))
    (daq.ll:property-object/add-property prop-obj prop)

    (setf ref-name (daq.ll:make-daq-string "ref_property"))
    (setf eval-str (daq.ll:make-daq-string "%test_property"))
    (setf eval-value (daq.ll:eval-value/create-eval-value eval-str))
    (setf ref-prop (daq.ll:property/create-reference-property ref-name eval-value))
    (daq.ll:property-object/add-property prop-obj ref-prop)

    (setf value (daq.ll:property-object/get-property-value prop-obj ref-name))
    (is (= 10 (daq.ll:integer/get-value value))
        "coreobjects/EvalValue value mismatch")))

(test coreobjects-permissions
  (daq.ll:with-daq-objects (admin-groups guest-groups admin-name guest-name password admin guest
                         manager mask-builder permissions-builder admin-permissions)
    (setf admin-groups (daq.ll:list/create-list))
    (setf guest-groups (daq.ll:list/create-list))
    (setf admin-name (daq.ll:make-daq-string "admin"))
    (setf guest-name (daq.ll:make-daq-string "guest"))
    (setf password (daq.ll:make-daq-string "password"))

    (daq.ll:list/push-back admin-groups admin-name)
    (daq.ll:list/push-back admin-groups guest-name)
    (daq.ll:list/push-back guest-groups guest-name)

    (setf admin (daq.ll:user/create-user admin-name password admin-groups))
    (setf guest (daq.ll:user/create-user guest-name password guest-groups))
    (setf manager (daq.ll:permission-manager/create-permission-manager (cffi:null-pointer)))
    (setf mask-builder (daq.ll:permission-mask-builder/create-permission-mask-builder))
    (daq.ll:permission-mask-builder/read mask-builder)
    (daq.ll:permission-mask-builder/write mask-builder)

    (setf permissions-builder (daq.ll:permissions-builder/create-permissions-builder))
    (daq.ll:permissions-builder/assign permissions-builder admin-name mask-builder)
    (setf admin-permissions (daq.ll:permissions-builder/build permissions-builder))
    (daq.ll:permission-manager/set-permissions manager admin-permissions)

    (is (= 1 (daq.ll:permission-manager/is-authorized manager admin :daq-permission-read))
        "coreobjects/Permissions admin read mismatch")
    (is (= 1 (daq.ll:permission-manager/is-authorized manager admin :daq-permission-write))
        "coreobjects/Permissions admin write mismatch")
    (is (= 0 (daq.ll:permission-manager/is-authorized manager admin :daq-permission-execute))
        "coreobjects/Permissions admin execute mismatch")
    (is (= 0 (daq.ll:permission-manager/is-authorized manager guest :daq-permission-read))
        "coreobjects/Permissions guest read mismatch")
    (is (= 0 (daq.ll:permission-manager/is-authorized manager guest :daq-permission-write))
        "coreobjects/Permissions guest write mismatch")
    (is (= 0 (daq.ll:permission-manager/is-authorized manager guest :daq-permission-execute))
        "coreobjects/Permissions guest execute mismatch")))

(test coreobjects-property
  (daq.ll:with-daq-objects (prop name default-value visible default-value-out name-out)
    (setf name (daq.ll:make-daq-string "test_property"))
    (setf default-value (daq.ll:integer/create-integer 10))
    (setf visible (daq.ll:boolean/create-boolean 1))
    (setf prop (daq.ll:property/create-int-property name default-value visible))
    (setf default-value-out (daq.ll:property/get-default-value prop))
    (is (= 10 (daq.ll:integer/get-value default-value-out))
        "coreobjects/Property default value mismatch")
    (setf name-out (daq.ll:property/get-name prop))
    (is (string= "test_property" (%daq-string-value name-out))
        "coreobjects/Property name mismatch")
    (is (= 1 (daq.ll:property/get-visible prop))
        "coreobjects/Property visible mismatch")))

(test coreobjects-property-builder
  (daq.ll:with-daq-objects (prop-builder name default-value visible property default-value-out name-out)
    (setf name (daq.ll:make-daq-string "test_property"))
    (setf default-value (daq.ll:integer/create-integer 10))
    (setf visible (daq.ll:boolean/create-boolean 1))
    (setf prop-builder (daq.ll:property-builder/create-int-property-builder name default-value))
    (daq.ll:property-builder/set-visible prop-builder visible)
    (setf property (daq.ll:property-builder/build prop-builder))
    (setf default-value-out (daq.ll:property/get-default-value property))
    (is (= 10 (daq.ll:integer/get-value default-value-out))
        "coreobjects/PropertyBuilder default value mismatch")
    (setf name-out (daq.ll:property/get-name property))
    (is (string= "test_property" (%daq-string-value name-out))
        "coreobjects/PropertyBuilder name mismatch")
    (is (= 1 (daq.ll:property/get-visible property))
        "coreobjects/PropertyBuilder visible mismatch")))

(test coreobjects-property-object
  (daq.ll:with-daq-objects (prop-obj prop name default-value visible prop-out)
    (setf prop-obj (daq.ll:property-object/create-property-object))
    (setf name (daq.ll:make-daq-string "test_property"))
    (setf default-value (daq.ll:integer/create-integer 10))
    (setf visible (daq.ll:boolean/create-boolean 1))
    (setf prop (daq.ll:property/create-int-property name default-value visible))
    (daq.ll:property-object/add-property prop-obj prop)
    (setf prop-out (daq.ll:property-object/get-property prop-obj name))
    (is (= 1 (daq.ll:base-object/equals prop prop-out))
        "coreobjects/PropertyObject property mismatch")
    (is (= 1 (daq.ll:property-object/has-property prop-obj name))
        "coreobjects/PropertyObject expected property before removal")
    (daq.ll:property-object/remove-property prop-obj name)
    (is (= 0 (daq.ll:property-object/has-property prop-obj name))
        "coreobjects/PropertyObject expected property removal")))

(test coreobjects-property-object-class
  (daq.ll:with-daq-objects (prop-obj-class builder name prop prop-name default-value visible prop-out)
    (setf name (daq.ll:make-daq-string "test_property_class"))
    (setf builder (daq.ll:property-object-class-builder/create-property-object-class-builder name))
    (setf prop-name (daq.ll:make-daq-string "test_property"))
    (setf default-value (daq.ll:integer/create-integer 10))
    (setf visible (daq.ll:boolean/create-boolean 1))
    (setf prop (daq.ll:property/create-int-property prop-name default-value visible))
    (daq.ll:property-object-class-builder/add-property builder prop)
    (setf prop-obj-class (daq.ll:property-object-class-builder/build builder))
    (setf prop-out (daq.ll:property-object-class/get-property prop-obj-class prop-name))
    (is (= 1 (daq.ll:base-object/equals prop prop-out))
        "coreobjects/PropertyObjectClass property mismatch")))

(test coreobjects-property-value-event-args
  (daq.ll:with-daq-objects (event-args prop name default-value visible value1 value2 value-out)
    (setf name (daq.ll:make-daq-string "test_property"))
    (setf default-value (daq.ll:integer/create-integer 10))
    (setf visible (daq.ll:boolean/create-boolean 1))
    (setf prop (daq.ll:property/create-int-property name default-value visible))
    (setf value1 (daq.ll:integer/create-integer 20))
    (setf value2 (daq.ll:integer/create-integer 30))
    (setf event-args
          (daq.ll:property-value-event-args/create-property-value-event-args
           prop
           value2
           value1
           :daq-property-event-type-event-type-update
           0))
    (setf value-out (daq.ll:property-value-event-args/get-value event-args))
    (is (= 1 (daq.ll:base-object/equals value-out value2))
        "coreobjects/PropertyValueEventArgs value mismatch")
    (setf value-out nil)
    (setf value-out (daq.ll:property-value-event-args/get-old-value event-args))
    (is (= 1 (daq.ll:base-object/equals value-out value1))
        "coreobjects/PropertyValueEventArgs old value mismatch")))

(test coreobjects-unit
  (daq.ll:with-daq-objects (unit-builder name symbol unit name-out symbol-out)
    (setf name (daq.ll:make-daq-string "test_unit"))
    (setf symbol (daq.ll:make-daq-string "tu"))
    (setf unit-builder (daq.ll:unit-builder/create-unit-builder))
    (daq.ll:unit-builder/set-name unit-builder name)
    (daq.ll:unit-builder/set-symbol unit-builder symbol)
    (setf unit (daq.ll:unit-builder/build unit-builder))
    (setf name-out (daq.ll:unit/get-name unit))
    (setf symbol-out (daq.ll:unit/get-symbol unit))
    (is (string= "test_unit" (%daq-string-value name-out))
        "coreobjects/Unit name mismatch")
    (is (string= "tu" (%daq-string-value symbol-out))
        "coreobjects/Unit symbol mismatch")))

(test coreobjects-user
  (daq.ll:with-daq-objects (username password-hash groups user username-out)
    (setf username (daq.ll:make-daq-string "test_user"))
    (setf password-hash (daq.ll:make-daq-string "test_hash"))
    (setf groups (daq.ll:list/create-list))
    (setf user (daq.ll:user/create-user username password-hash groups))
    (setf username-out (daq.ll:user/get-username user))
    (is (string= "test_user" (%daq-string-value username-out))
        "coreobjects/User username mismatch")))

(test coreobjects-validator
  (daq.ll:with-daq-objects (validator eval-str value invalid-value)
    (setf eval-str (daq.ll:make-daq-string "value > 5"))
    (setf validator (daq.ll:validator/create-validator eval-str))
    (setf value (daq.ll:integer/create-integer 10))
    (daq.ll:validator/validate validator (cffi:null-pointer) value)
    (setf invalid-value (daq.ll:integer/create-integer 3))
    (let ((saw-error nil))
      (handler-case
          (daq.ll:validator/validate validator (cffi:null-pointer) invalid-value)
        (daq:opendaq-error ()
          (setf saw-error t)))
      (daq:clear-error-info)
      (is (not (null saw-error))
          "coreobjects/Validator expected validation error for invalid value"))))
