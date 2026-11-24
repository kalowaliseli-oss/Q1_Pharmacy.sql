/* =====================================================================
   ICT371  QUESTION 1 - Pharmacy Stock and Daily Sales            [50]
   ===================================================================== */
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1, public;

-- Test helper (not part of the marked answer): runs a statement that is
-- SUPPOSED to fail and prints the error instead of stopping the script.
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;


/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - Money uses NUMERIC(10,2): exact decimals, never FLOAT (rounding errors).
   - "Positive prices" = CHECK (unit_price > 0) on BOTH medicines and sales.
   - "Non-negative stock" = CHECK (stock_qty >= 0). This is also the last
     line of defence against overselling: even a faulty UPDATE that would
     push stock below zero is refused by the database.
   - Medicines are inserted directly; SALES are loaded later through
     pr_record_sale (as the question demands), after the procedure and
     trigger exist, so the stock deductions are also audited.
   --------------------------------------------------------------------- */
CREATE TABLE medicines (
    medicine_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name  VARCHAR(100)  NOT NULL UNIQUE,
    unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty      INTEGER       NOT NULL DEFAULT 0 CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id  INTEGER       NOT NULL REFERENCES medicines (medicine_id),
    quantity     INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),  -- price AT TIME OF SALE
    sold_on      DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id  INTEGER     NOT NULL REFERENCES medicines (medicine_id),
    old_qty      INTEGER     NOT NULL,
    new_qty      INTEGER     NOT NULL,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date    DATE          PRIMARY KEY,
    total_qty     INTEGER       NOT NULL CHECK (total_qty >= 0),
    total_amount  NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg (strip of 10)', 12.50, 120),
    ('Amoxicillin 250mg (strip of 10)', 35.00,  40),
    ('ORS sachet',                       4.00,  15);


/* ---------------------------------------------------------------------
   (b) FUNCTION fn_sale_value                                       [6]
   - Validates quantity first (cheap check, no table access).
   - SELECT ... INTO + IF NOT FOUND detects an unknown medicine.
   - STABLE: reads the table but changes nothing.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_price medicines.unit_price%TYPE;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity %: quantity must be a positive whole number', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM   medicines
    WHERE  medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine id %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;


/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_record_sale                                      [8]
   Requirement -> how it is met:
   - "Check available stock"   : read stock_qty and compare to p_quantity.
   - "Store the current price" : the price is copied from medicines into
                                 sales.unit_price, so later price changes
                                 do not rewrite history.
   - "Deduct stock exactly once": one UPDATE, inside this procedure only.
   - "Invalid sale leaves both tables unchanged": every check happens
     BEFORE the INSERT/UPDATE. Even if something failed after the INSERT,
     RAISE EXCEPTION aborts the whole CALL, and PostgreSQL rolls back
     everything that CALL did (statement atomicity).
   - SELECT ... FOR UPDATE locks the medicine row, so two cashiers selling
     the last packs at the same moment cannot both pass the stock check.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock medicines.stock_qty%TYPE;
    v_price medicines.unit_price%TYPE;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity %: quantity must be a positive whole number', p_quantity;
    END IF;
    IF p_sold_on IS NULL OR p_sold_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'Invalid sale date %: must be today or earlier', p_sold_on;
    END IF;

    SELECT stock_qty, unit_price
    INTO   v_stock, v_price
    FROM   medicines
    WHERE  medicine_id = p_medicine_id
    FOR UPDATE;                                   -- lock the row

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine id %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: % available, % requested',
                        p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET    stock_qty = stock_qty - p_quantity      -- the ONLY deduction
    WHERE  medicine_id = p_medicine_id;
END;
$$;


/* ---------------------------------------------------------------------
   (d) TRIGGER: AFTER UPDATE, FOR EACH ROW, on medicines             [8]
   - OLD = row before the update, NEW = row after it.
   - IS DISTINCT FROM (not <>) is the safe comparison: it treats NULLs
     correctly. If only the price changes, or stock is "updated" to the
     same value, no audit row is written.
   - AFTER trigger: the change has passed all constraints, so we never
     audit a change that is then rejected. Return value is ignored.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_medicines_stock_audit();


-- (a) continued: load six valid sales THROUGH the procedure ----------
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3,  4, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(2,  8, CURRENT_DATE - 1);
CALL pr_record_sale(1,  6, CURRENT_DATE);

SELECT * FROM medicines ORDER BY medicine_id;   -- stock reduced: 84, 27, 11
SELECT * FROM sales     ORDER BY sale_id;       -- 6 sales with stored prices

-- Tests for (b)
SELECT fn_sale_value(2, 3) AS value_3_amoxicillin;        -- 105.00
CALL expect_error('SELECT fn_sale_value(99, 1)');          -- unknown medicine
CALL expect_error('SELECT fn_sale_value(1, 0)');           -- invalid quantity

-- Tests for (c): an oversell must leave BOTH tables unchanged
SELECT (SELECT count(*) FROM sales) AS sales_before,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS ors_stock_before;
CALL expect_error('CALL pr_record_sale(3, 500, CURRENT_DATE)');   -- oversell
CALL expect_error('CALL pr_record_sale(42, 1, CURRENT_DATE)');    -- unknown id
CALL expect_error('CALL pr_record_sale(1, -2, CURRENT_DATE)');    -- bad quantity
SELECT (SELECT count(*) FROM sales) AS sales_after,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS ors_stock_after;  -- same as before

-- Tests for (d)
SELECT * FROM stock_audit ORDER BY audit_id;                -- 6 rows, one per sale
UPDATE medicines SET unit_price = 13.00 WHERE medicine_id = 1;          -- price only
UPDATE medicines SET stock_qty = stock_qty WHERE medicine_id = 2;       -- same value
SELECT count(*) AS audit_rows_still_6 FROM stock_audit;                 -- still 6
UPDATE medicines SET stock_qty = stock_qty + 30 WHERE medicine_id = 2;  -- restock
SELECT * FROM stock_audit ORDER BY audit_id DESC LIMIT 1;               -- 27 -> 57


/* ---------------------------------------------------------------------
   (e) VIEW v_low_stock                                              [5]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM   medicines
WHERE  stock_qty < 10;

SELECT * FROM v_low_stock;            -- empty: ORS has 11
CALL pr_record_sale(3, 3, CURRENT_DATE);
SELECT * FROM v_low_stock;            -- ORS sachet now appears with 8 left


/* ---------------------------------------------------------------------
   (f) INDEX                                                         [5]
   Query pattern: WHERE medicine_id = ?  AND  sold_on BETWEEN ? AND ?
   Justification:
   - A composite B-tree on (medicine_id, sold_on) puts the EQUALITY column
     first and the RANGE column second. Inside the index all entries for
     one medicine are stored together, already sorted by date, so the
     search jumps to (medicine, start date) and reads forward until the
     end date: one contiguous slice, no wasted rows.
   - The reverse order (sold_on, medicine_id) would scan every medicine's
     sales in the date range and filter afterwards.
   - It also indexes the foreign key, which speeds up FK checks.
   Note on EXPLAIN: with only a handful of rows the planner correctly
   prefers a sequential scan (the whole table fits in one page). Turning
   enable_seqscan off for one statement shows the plan the index gives,
   which is what the planner uses automatically once the table is large.
   --------------------------------------------------------------------- */
CREATE INDEX idx_sales_medicine_soldon ON sales (medicine_id, sold_on);
ANALYZE sales;

EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM   sales
WHERE  medicine_id = 1
AND    sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

SET enable_seqscan = off;
EXPLAIN ANALYZE
SELECT sale_id, quantity, unit_price, sold_on
FROM   sales
WHERE  medicine_id = 1
AND    sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;


/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   - One INSERT ... SELECT with aggregates. An aggregate query without
     GROUP BY always returns exactly one row, so a day with no sales is
     stored as 0 / 0.00 (COALESCE turns the NULL sums into zero).
   - ON CONFLICT (sales_date) DO UPDATE SET col = EXCLUDED.col REPLACES
     the old totals. It never adds to them (no "total_qty + ..."), so
     running it twice for the same day gives the same row: no duplicates,
     no double counting. EXCLUDED = the row we tried to insert.
   - SET search_path: the cron session does not know about schema q1.
   - Cron '15 0 * * *' = minute 15, hour 0, every day -> 00:15 daily.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
SET search_path = q1, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM   sales
    WHERE  sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET    total_qty    = EXCLUDED.total_qty,
           total_amount = EXCLUDED.total_amount;
END;
$$;

-- Rerun test: same answer every time
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 2);
SELECT * FROM daily_sales ORDER BY sales_date;   -- one row per day, correct totals

-- Schedule: daily at 00:15, for the PREVIOUS day
SELECT cron.schedule(
    'q1_refresh_daily_sales',
    '15 0 * * *',
    $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q1_refresh_daily_sales';
