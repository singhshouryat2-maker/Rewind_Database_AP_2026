-- Rewind Database ("Ctrl+Z for databases"): schema
-- Run on PostgreSQL:  psql -d rewind -f dbms/03_schema.sql

DROP TABLE IF EXISTS employees_history;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS users;

-- Who is allowed to change or restore data
CREATE TABLE users (
    user_id     SERIAL       PRIMARY KEY,
    username    VARCHAR(50)  NOT NULL UNIQUE,
    role        VARCHAR(10)  NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_user_role CHECK (role IN ('admin', 'editor', 'viewer'))
);

-- The normal, live table
CREATE TABLE employees (
    emp_id      INTEGER       PRIMARY KEY,
    name        VARCHAR(100)  NOT NULL,
    email       VARCHAR(100)  NOT NULL UNIQUE,
    department  VARCHAR(50)   NOT NULL,
    salary      NUMERIC(10,2) NOT NULL,
    CONSTRAINT chk_emp_email  CHECK (email LIKE '%_@_%._%'),
    CONSTRAINT chk_emp_salary CHECK (salary >= 0)
);

-- Every version of every employee row, ever
-- No foreign key to employees on purpose: history must survive a DELETE.
CREATE TABLE employees_history (
    history_id  BIGSERIAL     PRIMARY KEY,
    emp_id      INTEGER       NOT NULL,
    version_no  INTEGER       NOT NULL,
    name        VARCHAR(100)  NOT NULL,
    email       VARCHAR(100)  NOT NULL,
    department  VARCHAR(50)   NOT NULL,
    salary      NUMERIC(10,2) NOT NULL,
    operation   VARCHAR(6)    NOT NULL,
    changed_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    changed_by  INTEGER       NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    CONSTRAINT uq_history_version  UNIQUE (emp_id, version_no),
    CONSTRAINT chk_history_version CHECK (version_no > 0),
    CONSTRAINT chk_history_op      CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    CONSTRAINT chk_history_salary  CHECK (salary >= 0)
);
