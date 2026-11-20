# 05 · Query timings: Rewind Database

Each query from `dbms/04_queries.sql` ran 3 times with `EXPLAIN (ANALYZE, BUFFERS)` inside `BEGIN … ROLLBACK`.
Data: `dbms/seed_data.sql` (10,000 employees, about 22,000 history rows). Raw plans: `dbms/plans/`.

| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |
|-------|------|--------------|-----------:|-----------:|-----------:|-------------:|-----------|
| R1 | READ | sign-in, find the user and their role by username | 0.034 | 0.048 | 0.047 | 0.043 | Seq Scan on users |
| R2 | READ | show the live employees table | 5.091 | 5.286 | 4.320 | 4.899 | Seq Scan on employees |
| R3 | READ | audit log, every change with who made it (JOIN history with users) | 9.139 | 9.335 | 11.098 | 9.857 | Seq Scan on employees_history, Seq Scan on users |
| R4 | READ | the table "as of" a past time = latest version of each employee before that time | 92.245 | 57.249 | 69.254 | 72.916 | Seq Scan on employees_history |
| R5 | READ | the table as of 5 PM yesterday (date functions) | 60.422 | 78.588 | 71.287 | 70.099 | Seq Scan on employees_history |
| R6 | READ | latest version of every employee, including deleted ones (ROW_NUMBER) | 16.455 | 18.064 | 17.792 | 17.437 | Seq Scan on employees_history |
| R7 | READ | salary history of one employee, old value -> new value (LAG) | 0.157 | 0.090 | 0.166 | 0.138 | Bitmap Heap Scan on employees_history, Index Scan on uq_history_version |
| R8 | READ | label every change (CASE): new joiner, raise, pay cut, deleted, other edit | 12.920 | 15.648 | 16.418 | 14.995 | Seq Scan on employees_history |
| R9 | READ | compare each version with the one before it (SELF JOIN), only salary changes | 17.459 | 18.093 | 19.032 | 18.195 | Seq Scan on employees_history, Index Scan using users_pkey on users |
| R10 | READ | find the disaster, the rows whose salary was set to 0, who did it and the old value | 3.313 | 2.570 | 3.851 | 3.245 | Seq Scan on employees_history, Index Scan using uq_history_version on employees_history, Seq Scan on users |
| R11 | READ | who made the most changes (GROUP BY) | 13.231 | 13.196 | 7.005 | 11.144 | Seq Scan on employees_history, Seq Scan on users |
| R12 | READ | rows that changed more than 3 times (GROUP BY ... HAVING) | 10.009 | 8.992 | 7.457 | 8.819 | Seq Scan on employees_history |
| R13 | READ | exactly what changed between two times (EXCEPT between two snapshots) | 94.427 | 83.773 | 69.171 | 82.457 | Seq Scan on employees, Seq Scan on employees_history |
| R14 | READ | current salary with "still current" marker (COALESCE): employees deleted from the | 17.590 | 16.366 | 16.580 | 16.845 | Seq Scan on employees_history, Seq Scan on employees |
| W1 | WRITE | add a new employee (as editor rahul) | 2.114 | 1.781 | 1.800 | 1.898 | — |
| W2 | WRITE | give one employee a 10% raise | 2.023 | 1.828 | 1.619 | 1.823 | Index Scan using employees_pkey on employees |
| W3 | WRITE | the disaster, UPDATE without WHERE: every salary becomes 0 | 251.468 | 282.586 | 292.902 | 275.652 | Seq Scan on employees |
| W4 | WRITE | delete one employee | 1.804 | 1.686 | 1.525 | 1.672 | Index Scan using employees_pkey on employees |
| W5 | WRITE | RESTORE every salary to its value from one hour ago, in one query (admin only). | 70.518 | 69.228 | 95.701 | 78.482 | Seq Scan on employees, Index Scan using uq_history_version on employees_history |
| W6 | WRITE | UNDELETE, bring back employees that were deleted (their last version before the DELETE) | 45.408 | 53.246 | 45.700 | 48.118 | Seq Scan on employees_history, Seq Scan on employees |
