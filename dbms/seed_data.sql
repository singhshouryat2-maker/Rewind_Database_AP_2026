-- Rewind Database: sample data for demos and timings
-- Run after 03_schema.sql and the SETUP part of 04_queries.sql:  psql -d rewind -f dbms/seed_data.sql
-- Creates 3 users, 10,000 employees and about 22,000 history rows spread over the last 30 days.

TRUNCATE employees, employees_history, users RESTART IDENTITY;

INSERT INTO users (username, role) VALUES
    ('priya', 'admin'),
    ('rahul', 'editor'),
    ('meera', 'viewer');

-- 10,000 new joiners (the trigger writes version 1 of each)
SET rewind.user_id = '1';
INSERT INTO employees (emp_id, name, email, department, salary)
SELECT 100 + i,
       'Employee ' || i,
       'employee' || i || '@corp.in',
       (ARRAY['Sales', 'IT', 'HR', 'Finance', 'Operations'])[1 + i % 5],
       30000 + (i % 50) * 1000
FROM generate_series(1, 10000) AS i;

-- Three rounds of pay changes on different groups of employees
SET rewind.user_id = '2';
UPDATE employees SET salary = salary + 5000 WHERE emp_id % 2 = 0;
UPDATE employees SET salary = salary - 2000 WHERE emp_id % 3 = 0;
UPDATE employees SET department = 'IT'      WHERE emp_id % 7 = 0;
UPDATE employees SET salary = salary + 1000 WHERE emp_id % 4 = 0;

-- A few employees leave
SET rewind.user_id = '1';
DELETE FROM employees WHERE emp_id % 500 = 0;

-- Spread the history over the last 30 days: version 1 oldest, later versions newer
UPDATE employees_history
SET changed_at = now() - interval '30 days' + (version_no - 1) * interval '5 days'
                 + (emp_id % 1440) * interval '1 minute';

ANALYZE;
