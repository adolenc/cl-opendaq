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
  (let* ((argument-info (make-instance 'daq:argument-info :name "test_argument" :type :int))
         (arguments (make-instance 'daq:object-list)))
    (daq:push-back arguments argument-info)
    (let ((callable-info (make-instance 'daq:callable-info
                                        :argument-info arguments
                                        :return-type :int
                                        :const-flag t)))
      (is (string= "test_argument" (daq:name argument-info)) "High-level argument info wrappers should expose their name.")
      (is (eql :int (daq:argument-info-type argument-info)) "High-level argument info wrappers should expose their core type.")
      (is (= 1 (list-length (daq:arguments callable-info))) "High-level callable-info wrappers should preserve their argument list.")
      (is (eql :int (daq:return-type callable-info)) "High-level callable-info wrappers should expose their return type.")
      (is (daq:is-const callable-info) "High-level callable-info wrappers should preserve the const flag."))))

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
               (make-instance 'daq:authentication-provider/static :allow-anonymous t :user-list users))
             (anonymous-user (daq:authenticate-anonymous authentication-provider))
             (authenticated-user (daq:authenticate authentication-provider "test_user" "test_hash"))
             (found-user (daq:find-user authentication-provider "test_user"))
             (user-groups (daq:groups user)))
        (is (string= "test_user" (daq:username user)) "High-level user wrappers should expose their username.")
        (is (listp user-groups) "High-level user wrappers should expose their groups as a Lisp list.")
        (is (typep anonymous-user 'daq:user) "High-level authentication providers should synthesize an anonymous user when enabled.")
        (is (string= "test_user" (daq:username authenticated-user)) "High-level authentication providers should authenticate known users.")
        (is (string= "test_user" (daq:username found-user)) "High-level authentication providers should resolve users by name.")))))

(test high-level-coreobjects-property-builders
  (let* ((default-value (make-instance 'daq:integer-object :value 10))
         (visible-flag (make-instance 'daq:boolean-object :value t))
         (property (make-instance 'daq:property/int :name "test_property" :default-value default-value :visible visible-flag))
         (property-builder (make-instance 'daq:property-builder/int :name "test_property" :default-value default-value)))
    (setf (daq:visible property-builder) visible-flag)
    (let* ((built-property (daq:build property-builder))
           (built-default (daq:default-value built-property))
           (property-object (make-instance 'daq:property-object))
           (property-class-builder (make-instance 'daq:property-object-class-builder :name "test_property_class")))
      (daq:add-property property-object property)
      (daq:add-property property-class-builder property)
      (let* ((property-object-property (daq:property property-object "test_property"))
             (property-default (daq:default-value property-object-property))
             (property-class (daq:build property-class-builder))
             (class-property (daq:property property-class "test_property")))
        (is (string= "test_property" (daq:name property)) "High-level property factories should preserve the property name.")
        (is (= 10 (%boxed-integer-value built-default)) "High-level property builders should preserve their default value.")
        (is (daq:visible built-property) "High-level built properties should expose their visibility as a Lisp boolean.")
        (is (daq:has-property property-object "test_property") "High-level property objects should contain added properties.")
        (is (= 10 (%boxed-integer-value property-default)) "High-level property objects should expose the property's boxed default value.")
        (is (daq:has-property property-class "test_property") "High-level property-object-class builders should contain added properties.")
        (is (string= "test_property" (daq:name class-property)) "High-level property-object classes should expose their class property by name.")
        (daq:remove-property property-object "test_property")
        (is (not (daq:has-property property-object "test_property")) "High-level property objects should remove properties through the generated API.")))))

(test high-level-coreobjects-factory-proxies-plain-values
  (let ((int-property (make-instance 'daq:property/int :name "test_property" :default-value 10 :visible t))
        (float-property (make-instance 'daq:property/float :name "test_float" :default-value 1.5d0 :visible t))
        (bool-property (make-instance 'daq:property/bool :name "test_bool" :default-value nil :visible t))
        (linear-rule (make-instance 'daq:data-rule/linear :delta 2 :start 0)))
    (is (typep int-property 'daq:property) "A property/int proxy should be a subclass instance of property.")
    (is (= 10 (%boxed-integer-value (daq:default-value int-property))) "property/int should box a plain integer default value.")
    (is (= 1.5d0 (daq:unbox (daq:as (daq:default-value float-property) 'daq:float-object))) "property/float should box a plain float default value.")
    (is (not (%boxed-boolean-value (daq:default-value bool-property))) "property/bool should box a plain boolean default value.")
    (is (typep linear-rule 'daq:data-rule) "data-rule/linear should accept plain numeric arguments and build a data-rule.")))

(test high-level-coreobjects-property-value-unboxes-scalars
  ;; PROPERTY-VALUE's :around converts a scalar property to its native Lisp value,
  ;; so the caller needs no AS/UNBOX; a non-scalar (here an object property) has no
  ;; single value to unbox and is handed back as the raw wrapper.
  (let ((property-object (make-instance 'daq:property-object)))
    (daq:add-property property-object (make-instance 'daq:property/int :name "anint" :default-value 10 :visible t))
    (daq:add-property property-object (make-instance 'daq:property/float :name "afloat" :default-value 1.5d0 :visible t))
    (daq:add-property property-object (make-instance 'daq:property/string :name "astring" :default-value "hi" :visible t))
    (daq:add-property property-object (make-instance 'daq:property/bool :name "abool" :default-value t :visible t))
    (daq:add-property property-object (make-instance 'daq:property/ratio :name "aratio" :default-value (make-instance 'daq:ratio-object :numerator 1 :denominator 2) :visible t))
    (daq:add-property property-object (make-instance 'daq:property/object :name "anobject" :default-value (make-instance 'daq:property-object)))
    (is (eql 10 (daq:property-value property-object "anint")) "A scalar INT property should come back as a native integer.")
    (is (= 1.5d0 (daq:property-value property-object "afloat")) "A scalar FLOAT property should come back as a native float.")
    (is (string= "hi" (daq:property-value property-object "astring")) "A scalar STRING property should come back as a native string.")
    (is (eq t (daq:property-value property-object "abool")) "A scalar BOOL property should come back as a native boolean.")
    (is (= 1/2 (daq:property-value property-object "aratio")) "A scalar RATIO property should come back as a native ratio.")
    (is (daq:typep (daq:property-value property-object "anobject") 'daq:property-object) "An OBJECT property has no scalar value to unbox, so it stays a daq wrapper.")))

(test high-level-coreobjects-eval-coercer-validator
  (let* ((property-object (make-instance 'daq:property-object))
         (default-value (make-instance 'daq:integer-object :value 10))
         (visible-flag (make-instance 'daq:boolean-object :value t))
         (property (make-instance 'daq:property/int :name "test_property" :default-value default-value :visible visible-flag))
         (coercer (make-instance 'daq:coercer :eval "value + 2"))
         (validator (make-instance 'daq:validator :eval "value > 5")))
    (daq:add-property property-object property)
    (let ((eval-value (make-instance 'daq:eval-value :eval "%test_property")))
      (daq:add-property property-object
                        (make-instance 'daq:property/reference :name "ref_property" :referenced-property-eval eval-value))
      (let* ((valid-value (make-instance 'daq:integer-object :value 10))
             (invalid-value (make-instance 'daq:integer-object :value 5))
             (reference-property (daq:property-value property-object "ref_property"))
             (coerced-value (daq:coerce coercer property-object valid-value)))
        (is (= 10 reference-property) "High-level eval-value references should resolve through property-object/property-value, unboxed to a native value.")
        (is (string= "value + 2" (daq:eval coercer)) "High-level coercers should expose their configured expression.")
        (is (= 12 (%boxed-integer-value coerced-value)) "High-level coercers should transform the boxed value through the generated API.")
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
  (let* ((default-value (make-instance 'daq:integer-object :value 10))
         (visible-flag (make-instance 'daq:boolean-object :value t))
         (property (make-instance 'daq:property/int :name "test_property" :default-value default-value :visible visible-flag))
         (old-value (make-instance 'daq:integer-object :value 20))
         (new-value (make-instance 'daq:integer-object :value 30))
         (event-args (make-instance 'daq:property-value-event-args
                                    :prop property
                                    :value new-value
                                    :old-value old-value
                                    :type :update
                                    :is-updating nil))
         (event-value (daq:value event-args))
         (event-old-value (daq:old-value event-args)))
    (is (string= "test_property"
                 (daq:name (daq:property event-args)))
        "High-level property-value-event-args should expose their property.")
    (is (= 30 (%boxed-integer-value event-value)) "High-level property-value-event-args should expose the new boxed value.")
    (is (= 20 (%boxed-integer-value event-old-value)) "High-level property-value-event-args should expose the previous boxed value.")
    (is (eql :update (daq:property-event-type event-args)) "High-level property-value-event-args should preserve the event type symbol.")
    (is (null (daq:is-updating event-args)) "High-level property-value-event-args should decode false updating flags into NIL.")))

(test high-level-coreobjects-unified-optional-generic
  ;; PROPERTY is one of the UNIFY_OPTIONAL generics: a single generic spanning a
  ;; zero-arg specializer (property-value-event-args, padding) and an extra-arg
  ;; specializer (property-object, required PROPERTY-NAME).  Exercise both correct
  ;; arities and both misuse errors (supplied-p rejection / required omission).
  (let* ((default-value (make-instance 'daq:integer-object :value 10))
         (visible-flag (make-instance 'daq:boolean-object :value t))
         (property (make-instance 'daq:property/int :name "test_property" :default-value default-value :visible visible-flag))
         (property-object (make-instance 'daq:property-object))
         (event-args (make-instance 'daq:property-value-event-args
                                    :prop property
                                    :value (make-instance 'daq:integer-object :value 30)
                                    :old-value (make-instance 'daq:integer-object :value 20)
                                    :type :update
                                    :is-updating nil)))
    (daq:add-property property-object property)
    (is (string= "test_property" (daq:name (daq:property property-object "test_property"))) "Unified PROPERTY should accept the extra PROPERTY-NAME argument on property-object.")
    (is (string= "test_property" (daq:name (daq:property event-args))) "Unified PROPERTY should work with no extra argument on property-value-event-args.")
    (signals (error "Unified PROPERTY should reject an extra argument on property-value-event-args.")
      (daq:property event-args "test_property"))
    (signals (error "Unified PROPERTY should require the PROPERTY-NAME argument on property-object.")
      (daq:property property-object))))

(test high-level-coreobjects-end-update-event
  (let* ((property-object (make-instance 'daq:property-object))
         (event (daq:on-end-update property-object))
         (handler (make-instance 'daq:event-handler
                                 :call (cffi:callback %high-level-coreobjects-on-property-object-update-end))))
    (setf *high-level-coreobjects-update-ended* nil)
    (daq:add-handler event handler)
    (daq:begin-update property-object)
    (daq:end-update property-object)
    (is (not (null *high-level-coreobjects-update-ended*)) "High-level property objects should emit the end-update event through the generated API.")))
