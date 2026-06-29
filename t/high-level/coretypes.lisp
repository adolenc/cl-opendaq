(in-package #:opendaq.tests)

(in-suite high-level-coretypes-suite)

(defparameter *high-level-coretypes-event-called* nil)

(cffi:defcallback %high-level-coretypes-on-event :void ((sender opendaq.low-level::daq-base-object)
                                                        (args opendaq.low-level::daq-base-object))
  (setf *high-level-coretypes-event-called* t)
  (opendaq.low-level:base-object/release-ref sender)
  (opendaq.low-level:base-object/release-ref args))

(test high-level-coretypes-primitives
  (let* ((base-object (daq::wrap (opendaq.low-level:base-object/create) 'daq:base-object))
         (wrapped-ratio (daq::wrap (opendaq.low-level:ratio/create-ratio 8 12) 'daq:ratio-object))
         (ratio (make-instance 'daq:ratio-object :numerator 6 :denominator 9))
         (simplified (daq:simplify ratio))
         (boolean (make-instance 'daq:boolean-object :value nil))
         (complex-number (make-instance 'daq:complex-number-object :real 1.0d0 :imaginary 2.0d0))
         (integer (make-instance 'daq:integer-object :value 1))
         (float-object (make-instance 'daq:float-object :value 1.0d0))
         (string-object (daq::wrap (opendaq.low-level:make-daq-string "test") 'daq:string-object))
         (simple-type (make-instance 'daq:simple-type :core-type :int))
         (version-info (make-instance 'daq:version-info :major 1 :minor 2 :patch 3))
         (binary-data (make-instance 'daq:binary-data :size 16)))
    (is (typep base-object 'daq:base-object) "High-level wrappers should be able to adopt low-level base-object pointers.")
    (is (= 8 (daq:numerator wrapped-ratio)) "Low-level ratio pointers should be consumable through the generated high-level namespace alias.")
    (is (= 12 (daq:denominator wrapped-ratio)) "Wrapped low-level ratios should preserve their denominator.")
    (is (= 6 (daq:numerator ratio)) "High-level ratios should preserve their numerator.")
    (is (= 9 (daq:denominator ratio)) "High-level ratios should preserve their denominator.")
    (is (= 2 (daq:numerator simplified)) "High-level ratio simplification should produce the reduced numerator.")
    (is (= 3 (daq:denominator simplified)) "High-level ratio simplification should produce the reduced denominator.")
    (is (null (daq:value boolean)) "High-level boolean wrappers should decode false values into NIL.")
    (is (= 1.0d0 (daq:real complex-number)) "High-level complex numbers should expose their real component.")
    (is (= 2.0d0 (daq:imaginary complex-number)) "High-level complex numbers should expose their imaginary component.")
    (is (= 1 (daq:value integer)) "High-level integer wrappers should expose their boxed value.")
    (is (= 1.0d0 (daq:value float-object)) "High-level float wrappers should expose their boxed value.")
    (is (string= "test" (%boxed-string-value string-object)) "High-level string wrappers should round-trip the native string.")
    (is (not (cffi:null-pointer-p (daq:raw-pointer simple-type))) "High-level simple-type wrappers should create a native type object.")
    (is (= 1 (daq:major version-info)) "High-level version-info wrappers should expose the major version.")
    (is (= 2 (daq:minor version-info)) "High-level version-info wrappers should expose the minor version.")
    (is (= 3 (daq:patch version-info)) "High-level version-info wrappers should expose the patch version.")
    (is (= 16 (daq:size binary-data)) "High-level binary-data wrappers should preserve their native buffer size.")))

(test high-level-coretypes-ratio-boxing
  ;; A native Lisp ratio passed as an argument should box into a daqRatio, and a
  ;; daqRatio should unbox back into a native Lisp ratio through the primitive path.
  (let ((list (make-instance 'daq:object-list)))
    (daq:push-back list 2/3)
    (is (= 2/3 (daq:unbox (daq:as (daq:pop-front list) 'daq:ratio-object))) "A boxed daqRatio should unbox into a native Lisp ratio via UNBOX."))
  (let ((list (make-instance 'daq:object-list)))
    (daq:push-back list 1/4)
    (daq:push-back list 3/8)
    (is (equal '(1/4 3/8) (daq:as-list-of list 'daq:ratio-object)) "daqRatios should unbox into native Lisp ratios via AS-LIST-OF.")))

(test high-level-coretypes-complex-boxing
  ;; A native Lisp complex passed as an argument should box into a complexNumber,
  ;; mirroring the daqComplexNumber -> Lisp complex unboxing in %BOXED-VALUE.
  (let ((list (make-instance 'daq:object-list)))
    (daq:push-back list #C(1.0d0 2.0d0))
    (is (= #C(1.0d0 2.0d0) (daq:unbox (daq:as (daq:pop-front list) 'daq:complex-number-object))) "A boxed complexNumber should unbox into a native Lisp complex via UNBOX."))
  (let ((list (make-instance 'daq:object-list)))
    (daq:push-back list #C(3.0d0 -4.0d0))
    (is (equal '(#C(3.0d0 -4.0d0)) (daq:as-list-of list 'daq:complex-number-object)) "complexNumbers should unbox into native Lisp complexes via AS-LIST-OF.")))

(test high-level-coretypes-unbox
  ;; UNBOX reads the native Lisp value of a boxed-primitive wrapper, using the
  ;; wrapper's own class; a generic base-object is AS'd to the right type first.
  (is (= 42 (daq:unbox (make-instance 'daq:integer-object :value 42))) "unbox should read an integer-object as an integer.")
  (is (= 1.5d0 (daq:unbox (make-instance 'daq:float-object :value 1.5d0))) "unbox should read a float-object as a float.")
  (is (null (daq:unbox (make-instance 'daq:boolean-object :value nil))) "unbox should read a false boolean-object as NIL.")
  (is (= 1/2 (daq:unbox (make-instance 'daq:ratio-object :numerator 1 :denominator 2))) "unbox should read a ratio-object as a Lisp ratio.")
  (let ((boxed-string (daq::wrap (opendaq.low-level:make-daq-string "hello") 'daq:base-object)))
    (is (string= "hello" (daq:unbox (daq:as boxed-string 'daq:string-object))) "unbox should read a base-object AS'd to string-object as a string."))
  (signals error (daq:unbox (make-instance 'daq:object-list)) "unbox should reject a non-primitive wrapper."))

(test high-level-coretypes-core-type->class
  ;; CORE-TYPE->CLASS bridges a DAQ-CORE-TYPE keyword (as VALUE-TYPE reports) to the
  ;; boxed-primitive class AS takes; non-scalar core types map to NIL.
  (is (eq 'daq:integer-object (daq:core-type->class :int)) "core-type->class should map :int to integer-object.")
  (is (eq 'daq:string-object (daq:core-type->class :string)) "core-type->class should map :string to string-object.")
  (is (eq 'daq:complex-number-object (daq:core-type->class :complex-number)) "core-type->class should map :complex-number to complex-number-object.")
  (is (null (daq:core-type->class :list)) "core-type->class should map a non-scalar core type to NIL.")
  ;; Round-trip: the class it returns is exactly what AS needs to cast a value of that
  ;; core type so UNBOX can read it.
  (let ((list (make-instance 'daq:object-list)))
    (daq:push-back list 7)
    (is (= 7 (daq:unbox (daq:as (daq:pop-front list) (daq:core-type->class :int)))) "unbox of (as value class) should read the value, with class from core-type->class.")))

(test high-level-coretypes-collections
  (let ((list (make-instance 'daq:object-list)))
    (daq:push-back list 1)
    (daq:push-back list 2)
    (daq:push-back list 3)
    (is (= 3 (daq:count list)) "High-level object lists should track the number of boxed elements.")
    (let ((popped (daq:pop-front list)))
      (is (= 1 (%boxed-integer-value popped)) "High-level object lists should return boxed values from POP-FRONT."))
    (let ((removed (daq:remove-at list 1)))
      (is (= 3 (%boxed-integer-value removed)) "High-level object lists should return boxed values from REMOVE-AT."))
    (daq:clear list)
    (is (= 0 (daq:count list)) "High-level object lists should support CLEAR.")
    (let ((dict (make-instance 'daq:dict)))
      (daq:set dict "key" "value")
      (is (= 1 (daq:count dict)) "High-level dictionaries should track inserted entries.")
      (let ((dict-value (daq:get dict "key")))
        (is (string= "value" (%boxed-string-value dict-value)) "High-level dictionaries should return boxed string values.")))))

(test high-level-coretypes-enumeration-and-structs
  (let* ((enumerators (make-instance 'daq:dict))
         (field-names (make-instance 'daq:object-list))
         (field-type (make-instance 'daq:simple-type :core-type :int))
         (field-types (make-instance 'daq:object-list))
         (type-manager (make-instance 'daq:type-manager)))
    (daq:set enumerators "One" 1)
    (daq:set enumerators "Two" 2)
    (daq:push-back field-names "int")
    (daq:push-back field-types field-type)
    (let* ((enumeration-type
             (make-instance 'daq:enumeration-type/with-values :type-name "MyEnum" :enumerators enumerators))
           (enumeration (make-instance 'daq:enumeration/with-type :type enumeration-type :value "Two"))
           (struct-type (make-instance 'daq:struct-type/no-defaults :name "test" :names field-names :types field-types)))
      (daq:add-type type-manager struct-type)
      (let* ((managed-type (daq:type-manager-type type-manager "test"))
             (struct-builder (make-instance 'daq:struct-builder :name "test" :type-manager type-manager)))
        (daq:set struct-builder "int" 10)
        (let* ((struct (daq:build struct-builder))
               (field-value (daq:get struct "int")))
          (is (= 2 (daq:count enumeration-type)) "High-level enumeration types should report their number of enumerators.")
          (is (= 2 (daq:int-value enumeration)) "High-level enumeration values should expose their numeric value.")
          (is (daq:has-type type-manager "test") "High-level type managers should track added struct types.")
          (is (string= "test" (daq:name managed-type)) "High-level type managers should resolve added types by name.")
          (is (= 10 (%boxed-integer-value field-value)) "High-level structs should preserve values assigned through the generated builder.")
          (daq:remove-type type-manager "test")
          (is (not (daq:has-type type-manager "test")) "High-level type managers should remove registered types."))))))

(test high-level-coretypes-events
  (let* ((event (make-instance 'daq:event))
         (event-args (make-instance 'daq:event-args :event-id 10 :event-name "test_event"))
         (handler (make-instance 'daq:event-handler :call (cffi:callback %high-level-coretypes-on-event)))
         (sender (daq::wrap (opendaq.low-level:base-object/create) 'daq:base-object)))
    (setf *high-level-coretypes-event-called* nil)
    (is (= 0 (daq:subscriber-count event)) "High-level events should start without subscribers.")
    (is (= 10 (daq:event-id event-args)) "High-level event arguments should expose their numeric event identifier.")
    (is (string= "test_event" (daq:event-name event-args)) "High-level event arguments should expose their event name.")
    (daq:add-handler event handler)
    (is (= 1 (daq:subscriber-count event)) "High-level events should register generated event handlers.")
    (daq:handle-event handler sender event-args)
    (is (not (null *high-level-coretypes-event-called*)) "High-level event handlers should invoke the supplied callback.")))

(test high-level-coretypes-event-handler-from-function
  ;; A plain Lisp function can be passed straight to ADD-HANDLER (no manual
  ;; cffi:defcallback, no ref releasing): SENDER and ARGS arrive wrapped and their
  ;; references are handled by GC.
  (let* ((event (make-instance 'daq:event))
         (captured (list nil))
         (handler (daq:add-handler event
                                   (lambda (sender args)
                                     (declare (ignore sender))
                                     (setf (first captured)
                                           (daq:event-name (daq:as args 'daq:event-args))))))
         (sender (daq::wrap (opendaq.low-level:base-object/create) 'daq:base-object))
         (event-args (make-instance 'daq:event-args :event-id 42 :event-name "fn_event")))
    (is (typep handler 'daq:event-handler) "add-handler with a function should return the created event-handler.")
    (is (= 1 (daq:subscriber-count event)) "add-handler with a function should subscribe it like any other handler.")
    (daq:handle-event handler sender event-args)
    (is (string= "fn_event" (first captured)) "A function passed to add-handler should run with the wrapped event args.")))

(test high-level-coretypes-event-handler-routing
  ;; Distinct function handlers must get distinct trampolines that route to their
  ;; own closures, and a slot freed by remove-handler must be reusable.
  (let* ((event (make-instance 'daq:event))
         (a nil) (b nil)
         (handler-a (daq:add-handler event (lambda (s args) (declare (ignore s args)) (setf a t))))
         (sender (daq::wrap (opendaq.low-level:base-object/create) 'daq:base-object))
         (event-args (make-instance 'daq:event-args :event-id 1 :event-name "e")))
    (daq:add-handler event (lambda (s args) (declare (ignore s args)) (setf b t)))
    (is (= 2 (daq:subscriber-count event)) "Two function handlers should both subscribe.")
    (daq:handle-event handler-a sender event-args)
    (is (and a (not b)) "Each function handler should route to its own closure.")
    (daq:remove-handler event handler-a)
    (setf a nil)
    (let ((handler-c (daq:add-handler event (lambda (s args) (declare (ignore s args)) (setf a 42)))))
      (daq:handle-event handler-c sender event-args)
      (is (eql 42 a) "A handler subscribed after a removal (reusing a freed slot) should still work."))))

(defun %probe-ratio-finalization ()
  (eval
   '(let* ((release-state (list nil))
          (weak-pointer
            (let ((ratio (make-instance 'daq:ratio-object
                                        :numerator 14
                                        :denominator 21
                                        :release-hook (lambda ()
                                                        (setf (car release-state) t)))))
              (trivial-garbage:make-weak-pointer ratio))))
      (loop repeat 200
           until (and (car release-state)
                      (null (trivial-garbage:weak-pointer-value weak-pointer)))
           do (trivial-garbage:gc :full t)
              (sleep 0.05))
      (values (car release-state)
             (null (trivial-garbage:weak-pointer-value weak-pointer))))))

(test high-level-ratio-automatic-release
  (multiple-value-bind (released wrapper-reclaimed-p)
      (%probe-ratio-finalization)
    (is (not (null released)) "High-level wrappers should release their native pointer when reclaimed by GC.")
    (is (not (null wrapper-reclaimed-p)) "High-level wrapper objects should themselves remain reclaimable after native cleanup.")))
