;;
;; Abstract classes to define the API to connect to a data source
;;
(in-package :pgloader.connection)

(defclass connection ()
  ((type   :initarg :type :accessor conn-type)
   (handle :initarg :conn :accessor conn-handle :initform nil))
  (:documentation "pgloader connection parameters, base class"))

(define-condition connection-error (error)
  ((type :initarg :type :reader connection-error-type)
   (mesg :initarg :mesg :reader connection-error-mesg)))

(defgeneric open-connection (connection &key)
  (:documentation "Open a connection to the data source."))

(defgeneric close-connection (connection)
  (:documentation "Close a connection to the data source."))

(defclass fd-connection (connection)
  ((uri  :initarg :uri  :accessor fd-uri)
   (arch :initarg :arch :accessor fd-arch)
   (path :initarg :path :accessor fd-path))
  (:documentation "pgloader connection parameters for a file based data source."))

(define-condition fd-connection-error (connection-error)
  ((path :initarg :path :reader connection-error-path))
  (:report (lambda (err stream)
             (format stream "Failed to open ~a file ~s: ~a"
                     (connection-error-type err)
                     (connection-error-path err)
                     (connection-error-mesg err)))))

(defmethod print-object ((fd fd-connection) stream)
  (print-unreadable-object (fd stream :type t :identity t)
    (let ((url (cond ((and (slot-boundp fd 'path) (slot-value fd 'path))
                      (slot-value fd 'path))
                     ((and (slot-boundp fd 'arch) (slot-value fd 'arch))
                      (slot-value fd 'arch))
                     ((and (slot-boundp fd 'uri) (slot-value fd 'uri))
                      (slot-value fd 'uri)))))
     (with-slots (type) fd
       (format stream "~a://~a" type url)))))

(defgeneric fetch-file (fd-connection)
  (:documentation "Suport for HTTP URI for files."))

(defgeneric expand (fd-connection)
  (:documentation "Suport for file archives."))

(defmethod expand ((fd fd-connection))
  "Expand the archive for the FD connection."
  (when (and (slot-boundp fd 'arch) (slot-value fd 'arch))
    (let ((archive-directory (expand-archive (fd-arch fd))))
      ;; if there's a single file in the archive, it must the the path
      (let ((files (uiop:directory-files archive-directory)))
        (if (= 1 (length files))
            (setf (fd-path fd) (first files))
            (setf (fd-path fd) archive-directory)))))
  fd)

(defmethod fetch-file ((fd fd-connection))
  "When the fd-connection has an URI slot, download its file."
  (when (and (slot-boundp fd 'uri) (slot-value fd 'uri))
    (let ((local-filename (http-fetch-file (fd-uri fd))))
      (if (archivep local-filename)
          (setf (fd-arch fd) local-filename)
          (setf (fd-path fd) local-filename))))
  fd)

(defclass db-connection (connection)
  ((name :initarg :name :accessor db-name)
   (host :initarg :host :accessor db-host)
   (port :initarg :port :accessor db-port)
   (user :initarg :user :accessor db-user)
   (pass :initarg :pass :accessor db-pass))
  (:documentation "pgloader connection parameters for a database service."))

(defmethod print-object ((c db-connection) stream)
  (print-unreadable-object (c stream :type t :identity t)
    (with-slots (type name host port user) c
      (format stream "~a://~a@~a:~a/~a" type user host port name))))

(define-condition db-connection-error (connection-error)
  ((host :initarg :host :reader connection-error-host)
   (port :initarg :port :reader connection-error-port)
   (user :initarg :user :reader connection-error-user))
  (:report (lambda (err stream)
             (format stream "Failed to connect to ~a at ~s ~@[(port ~d)~]~@[ as user ~s~]: ~a"
                     (connection-error-type err)
                     (connection-error-host err)
                     (connection-error-port err)
                     (connection-error-user err)
                     (connection-error-mesg err)))))

(defmacro with-connection ((var connection) &body forms)
  "Connect to DB-CONNECTION and handle any condition when doing so, and when
   connected execute FORMS in a protected way so that we always disconnect
   at the end."
  (let ((conn (gensym "conn")))
    `(let* ((,conn ,connection)
            (,var (handler-case
                      (open-connection ,conn)
                    (condition (e)
                      (cond ((typep ,connection 'fd-connection)
                             (error 'fd-connection-error
                                    :mesg (format nil "~a" e)
                                    :type (conn-type ,conn)
                                    :path (fd-path ,conn)))

                            ((typep ,connection 'db-connection)
                             (error 'db-connection-error
                                    :mesg (format nil "~a" e)
                                    :type (conn-type ,conn)
                                    :host (db-host ,conn)
                                    :port (db-port ,conn)
                                    :user (db-user ,conn))))))))
       (unwind-protect
            (progn ,@forms)
         (close-connection ,var)))))

