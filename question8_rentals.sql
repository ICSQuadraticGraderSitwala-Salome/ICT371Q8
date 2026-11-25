DROP SCHEMA public CASCADE;
CREATE SCHEMA public;



-- ============================================================
-- ICT371 - QUESTION 8: Car Rental and Daily Rentals
-- total_amount = days * daily_rate. Days = return_date - rental_date
-- ============================================================

-- ------------------------------------------------------------
-- (a) DATABASE AND SEED DATA
-- ------------------------------------------------------------
DROP TABLE IF EXISTS daily_rentals, rental_audit, rentals, cars, customers CASCADE;

CREATE TABLE customers (
  customer_id SERIAL PRIMARY KEY,
  customer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE cars (
  car_id SERIAL PRIMARY KEY,
  plate_number VARCHAR(20) NOT NULL UNIQUE,
  car_model VARCHAR(100) NOT NULL,
  daily_rate NUMERIC(8,2) NOT NULL CHECK (daily_rate > 0)
);

CREATE TABLE rentals (
  rental_id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(customer_id),
  car_id INT NOT NULL REFERENCES cars(car_id),
  rental_date DATE NOT NULL,
  return_date DATE NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'booked'
    CHECK (status IN ('booked', 'active', 'returned', 'cancelled')),
  total_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  CHECK (return_date > rental_date)
);

CREATE TABLE rental_audit (
  audit_id SERIAL PRIMARY KEY,
  rental_id INT NOT NULL REFERENCES rentals(rental_id),
  old_status VARCHAR(20) NULL,
  new_status VARCHAR(20) NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_rentals (
  rental_day DATE PRIMARY KEY,
  active_rentals INT NOT NULL DEFAULT 0,
  total_revenue NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (customer_number, full_name) VALUES
('CUS001', 'Peter Banda'),
('CUS002', 'Sarah Mwanza'),
('CUS003', 'Daniel Phiri');

INSERT INTO cars (plate_number, car_model, daily_rate) VALUES
('ABC123', 'Toyota Corolla', 80.00),
('XYZ456', 'Nissan Note', 60.00),
('DEF789', 'Toyota Hilux', 120.00);

-- ------------------------------------------------------------
-- (b) FUNCTION
-- fn_car_revenue(p_car_id, p_start, p_end)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_car_revenue(p_car_id INT, p_start DATE, p_end DATE)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_total NUMERIC(12,2);
BEGIN
  IF p_start IS NULL OR p_end IS NULL THEN RAISE EXCEPTION 'Start and end dates are required'; END IF;
  IF p_end <= p_start THEN RAISE EXCEPTION 'End must be after start'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cars WHERE car_id = p_car_id) THEN
    RAISE EXCEPTION 'Unknown car: %', p_car_id;
  END IF;
  SELECT COALESCE(SUM(total_amount), 0) INTO v_total FROM rentals
  WHERE car_id = p_car_id AND status <> 'cancelled'
    AND rental_date >= p_start AND rental_date < p_end;
  RETURN v_total;
END; $$;

-- ------------------------------------------------------------
-- (c) PROCEDURE
-- pr_rent_car(p_customer_id, p_car_id, p_rental_date, p_return_date)
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_rent_car(p_customer_id INT, p_car_id INT, p_rental_date DATE, p_return_date DATE)
LANGUAGE plpgsql AS $$
DECLARE v_rate NUMERIC(8,2);
DECLARE v_days INT;
BEGIN
  IF p_rental_date IS NULL OR p_return_date IS NULL THEN RAISE EXCEPTION 'Rental and return dates are required'; END IF;
  IF p_rental_date < CURRENT_DATE THEN RAISE EXCEPTION 'Cannot rent in the past: %', p_rental_date; END IF;
  IF p_return_date <= p_rental_date THEN RAISE EXCEPTION 'Return date must be after rental date'; END IF;
  IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
    RAISE EXCEPTION 'Unknown customer: %', p_customer_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cars WHERE car_id = p_car_id) THEN
    RAISE EXCEPTION 'Unknown car: %', p_car_id;
  END IF;
  IF EXISTS (SELECT 1 FROM rentals WHERE car_id = p_car_id AND status <> 'cancelled'
    AND rental_date < p_return_date AND return_date > p_rental_date) THEN
    RAISE EXCEPTION 'Car % already rented for those dates', p_car_id;
  END IF;
  SELECT daily_rate INTO v_rate FROM cars WHERE car_id = p_car_id;
  v_days := p_return_date - p_rental_date;
  INSERT INTO rentals (customer_id, car_id, rental_date, return_date, status, total_amount)
  VALUES (p_customer_id, p_car_id, p_rental_date, p_return_date, 'booked', v_days * v_rate);
END; $$;

-- ------------------------------------------------------------
-- (d) TRIGGER
-- AFTER UPDATE on rentals -> rental_audit only if status changed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_rental_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO rental_audit (rental_id, old_status, new_status, changed_at)
    VALUES (NEW.rental_id, OLD.status, NEW.status, NOW());
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_rental_audit ON rentals;
CREATE TRIGGER trg_rental_audit
AFTER UPDATE ON rentals
FOR EACH ROW EXECUTE FUNCTION trg_rental_audit_fn();

-- ------------------------------------------------------------
-- (a) CONTINUED: Seed 6 rentals THROUGH procedure, no overlaps
-- ------------------------------------------------------------
CALL pr_rent_car(1, 1, '2026-11-25', '2026-11-27');
CALL pr_rent_car(2, 2, '2026-11-25', '2026-11-26');
CALL pr_rent_car(3, 3, '2026-11-25', '2026-11-28');
CALL pr_rent_car(1, 2, '2026-11-27', '2026-11-29');
CALL pr_rent_car(2, 1, '2026-11-28', '2026-11-30');
CALL pr_rent_car(3, 3, '2026-11-29', '2026-11-30');

-- Change 2 statuses to test trigger - 1 active, 1 cancelled
UPDATE rentals SET status = 'active' WHERE rental_id = 1;
UPDATE rentals SET status = 'cancelled' WHERE rental_id = 2;

-- ------------------------------------------------------------
-- (e) VIEW
-- v_current_rentals - not cancelled/returned and return_date >= today
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_current_rentals AS
SELECT r.rental_id, c.full_name AS customer_name, ca.plate_number, ca.car_model,
  r.rental_date, r.return_date, r.status, r.total_amount
FROM rentals r
JOIN customers c ON c.customer_id = r.customer_id
JOIN cars ca ON ca.car_id = r.car_id
WHERE r.status IN ('booked', 'active') AND r.return_date >= CURRENT_DATE;

SELECT * FROM v_current_rentals;

-- ------------------------------------------------------------
-- (f) INDEX
-- For a car's rentals within a date range
-- ------------------------------------------------------------
CREATE INDEX idx_rentals_car_date ON rentals (car_id, rental_date);

EXPLAIN ANALYZE
SELECT * FROM rentals
WHERE car_id = 1 AND rental_date BETWEEN '2026-11-25' AND '2026-11-30';

-- ------------------------------------------------------------
-- (g) SCHEDULED JOB
-- pr_refresh_rentals(p_day) - replace row on rerun
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_rentals(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'Day is required'; END IF;
  INSERT INTO daily_rentals (rental_day, active_rentals, total_revenue)
  SELECT p_day,
    COUNT(*) FILTER (WHERE status <> 'cancelled'),
    COALESCE(SUM(total_amount) FILTER (WHERE status <> 'cancelled'), 0)
  FROM rentals WHERE rental_date <= p_day AND return_date > p_day
  ON CONFLICT (rental_day) DO UPDATE
  SET active_rentals = EXCLUDED.active_rentals,
      total_revenue = EXCLUDED.total_revenue;
END; $$;

CALL pr_refresh_rentals('2026-11-25');
CALL pr_refresh_rentals('2026-11-25');

SELECT * FROM daily_rentals;
SELECT * FROM rental_audit ORDER BY audit_id;
SELECT fn_car_revenue(1, '2026-11-25', '2026-11-30') AS car1_revenue;
SELECT fn_car_revenue(3, '2026-11-25', '2026-11-30') AS car3_revenue;

-- Schedule: Daily at 00:55
-- SELECT cron.schedule('q8_refresh_rentals', '55 0 * * *', $$CALL pr_refresh_rentals(CURRENT_DATE - 1);$$);
