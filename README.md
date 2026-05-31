# openDAQ Common Lisp bindings

Common Lisp bindings for openDAQ.

## Quickstart

Install the library as a Quicklisp local project by cloning it into `~/quicklisp/local-projects/opendaq/`.
Then, load it in your REPL. The default `daq:` namespace is now the high-level API; the
existing generated low-level wrappers are available explicitly under `daq.ll:`. Here is
the low-level device-reading example:

```lisp
(ql:quickload :opendaq)

(daq.ll:with-daq-objects (builder module-path instance root-device connection-string device
                       channel-path signal-path frequency-name frequency-value
                       channel signal reader)
  (setf builder (daq.ll:instance-builder/create-instance-builder))
  (setf module-path (daq.ll:make-daq-string (namestring (daq:native-library-directory))))
  (daq.ll:instance-builder/set-module-path builder module-path)
  (daq.ll:instance-builder/enable-standard-providers builder 1)
  (setf instance (daq.ll:instance-builder/build builder))

  (setf root-device (daq.ll:instance/get-root-device instance))
  (setf connection-string (daq.ll:make-daq-string "daqref://device0"))
  (setf device (daq.ll:device/add-device root-device connection-string (cffi:null-pointer)))

  (setf channel-path (daq.ll:make-daq-string "/openDAQDevice/Dev/RefDev0/IO/AI/RefCh0"))
  (setf signal-path (daq.ll:make-daq-string "/openDAQDevice/Dev/RefDev0/IO/AI/RefCh0/Sig/AI0"))
  (setf channel (daq.ll:component/find-component instance channel-path))
  (setf signal (daq.ll:component/find-component instance signal-path))

  (setf frequency-name (daq.ll:make-daq-string "Frequency"))
  (setf frequency-value (daq.ll:float-object/create-float 0.5d0))
  (daq.ll:property-object/set-property-value channel frequency-name frequency-value)

  (setf reader
        (daq.ll:stream-reader/create-stream-reader
         signal
         daq.ll::+daq-sample-type-float-64+
         daq.ll::+daq-sample-type-int-64+
         :daq-read-mode-scaled
         :daq-read-timeout-type-any))

  (sleep 0.05)

  (let ((sample-count 100))
    (cffi:with-foreign-object (samples :double sample-count)
      (loop with total = 0
            while (< total sample-count)
            do (multiple-value-bind (count status)
                   (daq.ll:stream-reader/read
                    reader
                    (cffi:inc-pointer samples (* total (cffi:foreign-type-size :double)))
                    (- sample-count total)
                    1000)
                 (declare (ignore status))
                 (if (zerop count)
                     (sleep 0.01)
                     (incf total count)))
            finally (return
                      (loop for i below sample-count
                            collect (cffi:mem-aref samples :double i)))))))
```

This should give you an output of 100 samples from the reference device, which is a sine wave at 0.5Hz.

If that fails, run a healthcheck to verify that the library can find and load the native openDAQ libraries correctly:
```lisp
(daq:healthcheck)
```

## Experimental high-level slice

The default `daq:` namespace now resolves to the first generated high-level wrapper
layer in `opendaq.high-level` (`daq`, with `daq.hl` kept as an alias). The existing
generated low-level API is available explicitly in `opendaq` (`daq.ll`). The
first high-level vertical slice is `ratio`:

```lisp
(ql:quickload :opendaq)

(let* ((ratio (make-instance 'daq:ratio :numerator 6 :denominator 9))
       (simplified (daq:simplify ratio)))
  (list (daq:numerator ratio)
        (daq:denominator ratio)
        (daq:numerator simplified)
        (daq:denominator simplified)))
;; => (6 9 2 3)
```

This high-level layer is intentionally small for now so the package split, constructor
mapping, and lifetime management can be proven on a single type before it is expanded
across the rest of the bindings.

High-level wrappers now release their native references automatically when the Lisp
object is garbage-collected. `daq:release` is still available when you want prompt,
deterministic cleanup instead of waiting for GC.

## Development

The attached makefile is used for aiding with development. It handles cloning the pinned openDAQ source, building the native libraries, copying them into `bin/`, and regenerating the generated Lisp bindings. It also has targets for starting a REPL with the system loaded and running the test suite.

### Makefile

```bash
make bindings # clone pinned openDAQ source, build native libs, copy them into bin/, regenerate generated/bindings.lisp and generated/high-level-bindings.lisp
make repl     # start SBCL with the opendaq system loaded
make test     # run the FiveAM test suite
make clean    # remove bin/ and tmp/
```

Override OPENDAQ_REF in the Makefile if you want a different upstream version.

### Folder structure

- `opendaq.asd` - ASDF system definition
- `package.lisp`, `loader.lisp`, `utils.lisp`, `errors.lisp`, `high-level-runtime.lisp` - handwritten runtime layer
- `generated/` - autogenerated low-level and high-level bindings
- `t/` - FiveAM test files, ported from the c bindings test suite
- `tools/` - helper scripts such as the bindings generator
- `bin/` - bundled native openDAQ libraries loaded at runtime
- `tmp/` - temporary clone/build workspace used by `make bindings`
