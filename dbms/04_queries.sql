-- Rewind Database ("Ctrl+Z for databases"): every SQL query the app uses
-- Run after dbms/03_schema.sql:  psql -d rewind -f dbms/04_queries.sql
-- Each query has an id (R1.. for READ, W1.. for WRITE) and is marked -- READ or -- WRITE.
-- The app tells the database who is acting with:  SET rewind.user_id = '<user_id>';

-- =====================================================================
-- SETUP (run once): the trigger that records every change
-- =====================================================================

-- Every INSERT / UPDATE / DELETE on employees writes a full copy of the row into
-- employees_history in the SAME transaction (TCL): if the history insert fails,
-- the change is rolled back too, so history is never lost.
CREATE OR REPLACE FUNCTION log_employee_change() RETURNS trigger AS $$
DECLARE
    r employees%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        r := OLD;
    ELSE
        r := NEW;
    END IF;

    INSERT INTO employees_history (emp_id, version_no, name, email, department, salary,
                                   operation, changed_by)
    VALUES (r.emp_id,
            (SELECT COALESCE(max(version_no), 0) + 1 FROM employees_history WHERE emp_id = r.emp_id),
            r.name, r.email, r.department, r.salary,
            TG_OP,
            current_setting('rewind.user_id')::int);

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_employees_history ON employees;
CREATE TRIGGER trg_employees_history
AFTER INSERT OR UPDATE OR DELETE ON employees
FOR EACH ROW EXECUTE FUNCTION log_employee_change();

-- DCL: normal users can only read; only the admin can change or restore data.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewind_viewer') THEN
        CREATE ROLE rewind_viewer;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewind_admin') THEN
        CREATE ROLE rewind_admin;
    END IF;
END $$;

REVOKE ALL ON employees, employees_history, users FROM PUBLIC;
GRANT SELECT ON employees, employees_history, users TO rewind_viewer;
GRANT SELECT, INSERT, UPDATE, DELETE ON employees TO rewind_admin;
GRANT SELECT, INSERT ON employees_history TO rewind_admin;
GRANT SELECT ON users TO rewind_admin;
GRANT USAGE ON SEQUENCE employees_history_history_id_seq TO rewind_admin;

-- =====================================================================
-- READ queries
-- =====================================================================

-- @R1
-- READ: sign-in, find the user and their role by username
SELECT user_id, username, role
FROM users
WHERE username = 'priya';

-- @R2
-- READ: show the live employees table
SELECT emp_id, name, department, salary
FROM employees
ORDER BY emp_id;

-- @R3
-- READ: audit log, every change with who made it (JOIN history with users)
SELECT h.changed_at, u.username, u.role, h.operation, h.emp_id, h.name, h.salary
FROM employees_history h
JOIN users u ON u.user_id = h.changed_by
ORDER BY h.changed_at DESC, h.history_id DESC
LIMIT 50;

-- @R4
-- READ: the table "as of" a past time = latest version of each employee before that time
-- (correlated subquery), leaving out employees whose latest version was a DELETE
SELECT h.emp_id, h.name, h.department, h.salary
FROM employees_history h
WHERE h.changed_at <= now() - interval '1 hour'
  AND h.operation <> 'DELETE'
  AND h.version_no = (SELECT max(h2.version_no)
                      FROM employees_history h2
                      WHERE h2.emp_id = h.emp_id
                        AND h2.changed_at <= now() - interval '1 hour')
ORDER BY h.emp_id;

-- @R5
-- READ: the table as of 5 PM yesterday (date functions)
SELECT h.emp_id, h.name, h.department, h.salary
FROM employees_history h
WHERE h.changed_at <= (current_date - 1) + time '17:00'
  AND h.operation <> 'DELETE'
  AND h.version_no = (SELECT max(h2.version_no)
                      FROM employees_history h2
                      WHERE h2.emp_id = h.emp_id
                        AND h2.changed_at <= (current_date - 1) + time '17:00')
ORDER BY h.emp_id;

-- @R6
-- READ: latest version of every employee, including deleted ones (ROW_NUMBER)
SELECT emp_id, name, salary, operation, changed_at
FROM (SELECT h.*,
             ROW_NUMBER() OVER (PARTITION BY h.emp_id ORDER BY h.version_no DESC) AS rn
      FROM employees_history h) latest
WHERE rn = 1
ORDER BY emp_id;

-- @R7
-- READ: salary history of one employee, old value -> new value (LAG)
SELECT version_no, changed_at, operation,
       LAG(salary) OVER (ORDER BY version_no) AS old_salary,
       salary AS new_salary
FROM employees_history
WHERE emp_id = 101
ORDER BY version_no;

-- @R8
-- READ: label every change (CASE): new joiner, raise, pay cut, deleted, other edit
SELECT h.emp_id, h.version_no, h.changed_at,
       CASE
           WHEN h.operation = 'INSERT' THEN 'new joiner'
           WHEN h.operation = 'DELETE' THEN 'deleted'
           WHEN h.salary > prev.salary THEN 'raise'
           WHEN h.salary < prev.salary THEN 'pay cut'
           ELSE 'other edit'
       END AS change_type
FROM employees_history h
LEFT JOIN employees_history prev
       ON prev.emp_id = h.emp_id AND prev.version_no = h.version_no - 1
ORDER BY h.changed_at DESC
LIMIT 50;

-- @R9
-- READ: compare each version with the one before it (SELF JOIN), only salary changes
SELECT cur.emp_id, cur.name, prev.salary AS before, cur.salary AS after,
       cur.changed_at, u.username AS changed_by
FROM employees_history cur
JOIN employees_history prev ON prev.emp_id = cur.emp_id AND prev.version_no = cur.version_no - 1
JOIN users u                ON u.user_id = cur.changed_by
WHERE cur.salary <> prev.salary
ORDER BY cur.changed_at DESC
LIMIT 50;

-- @R10
-- READ: find the disaster, the rows whose salary was set to 0, who did it and the old value
SELECT cur.emp_id, cur.name, prev.salary AS old_salary, cur.changed_at, u.username
FROM employees_history cur
JOIN employees_history prev ON prev.emp_id = cur.emp_id AND prev.version_no = cur.version_no - 1
JOIN users u                ON u.user_id = cur.changed_by
WHERE cur.operation = 'UPDATE' AND cur.salary = 0 AND prev.salary > 0
ORDER BY cur.changed_at DESC;

-- @R11
-- READ: who made the most changes (GROUP BY)
SELECT u.username, u.role, count(*) AS changes
FROM employees_history h
JOIN users u ON u.user_id = h.changed_by
GROUP BY u.username, u.role
ORDER BY changes DESC;

-- @R12
-- READ: rows that changed more than 3 times (GROUP BY ... HAVING)
SELECT emp_id, count(*) AS versions
FROM employees_history
GROUP BY emp_id
HAVING count(*) > 3
ORDER BY versions DESC, emp_id;

-- @R13
-- READ: exactly what changed between two times (EXCEPT between two snapshots)
-- rows present now that were not identical one hour ago
SELECT emp_id, name, department, salary FROM employees
EXCEPT
SELECT h.emp_id, h.name, h.department, h.salary
FROM employees_history h
WHERE h.changed_at <= now() - interval '1 hour'
  AND h.operation <> 'DELETE'
  AND h.version_no = (SELECT max(h2.version_no)
                      FROM employees_history h2
                      WHERE h2.emp_id = h.emp_id
                        AND h2.changed_at <= now() - interval '1 hour')
ORDER BY emp_id;

-- @R14
-- READ: current salary with "still current" marker (COALESCE): employees deleted from the
-- live table show their last known salary from history
SELECT l.emp_id, l.name,
       COALESCE(e.salary, l.salary) AS salary,
       COALESCE(e.department, 'deleted') AS status
FROM (SELECT DISTINCT ON (emp_id) emp_id, name, salary
      FROM employees_history
      ORDER BY emp_id, version_no DESC) l
LEFT JOIN employees e ON e.emp_id = l.emp_id
ORDER BY l.emp_id;

-- =====================================================================
-- WRITE queries (the trigger logs each one automatically)
-- =====================================================================

-- @W1
-- WRITE: add a new employee (as editor rahul)
SET rewind.user_id = '2';
INSERT INTO employees (emp_id, name, email, department, salary)
VALUES (999001, 'Demo Joiner', 'demo.joiner@corp.in', 'IT', 45000);

-- @W2
-- WRITE: give one employee a 10% raise
SET rewind.user_id = '2';
UPDATE employees SET salary = round(salary * 1.10, 2) WHERE emp_id = 101;

-- @W3
-- WRITE: the disaster, UPDATE without WHERE: every salary becomes 0
SET rewind.user_id = '2';
UPDATE employees SET salary = 0;

-- @W4
-- WRITE: delete one employee
SET rewind.user_id = '2';
DELETE FROM employees WHERE emp_id = 102;

-- @W5
-- WRITE: RESTORE every salary to its value from one hour ago, in one query (admin only).
-- Runs as one transaction (TCL): either every row is restored or none is.
SET rewind.user_id = '1';
UPDATE employees e
SET name = s.name, department = s.department, salary = s.salary
FROM (SELECT h.emp_id, h.name, h.department, h.salary
      FROM employees_history h
      WHERE h.changed_at <= now() - interval '1 hour'
        AND h.operation <> 'DELETE'
        AND h.version_no = (SELECT max(h2.version_no)
                            FROM employees_history h2
                            WHERE h2.emp_id = h.emp_id
                              AND h2.changed_at <= now() - interval '1 hour')) s
WHERE e.emp_id = s.emp_id
  AND (e.name, e.department, e.salary) IS DISTINCT FROM (s.name, s.department, s.salary);

-- @W6
-- WRITE: UNDELETE, bring back employees that were deleted (their last version before the DELETE)
SET rewind.user_id = '1';
INSERT INTO employees (emp_id, name, email, department, salary)
SELECT h.emp_id, h.name, h.email, h.department, h.salary
FROM employees_history h
WHERE h.operation = 'DELETE'
  AND h.version_no = (SELECT max(version_no) FROM employees_history WHERE emp_id = h.emp_id)
  AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.emp_id = h.emp_id);

-- @END
