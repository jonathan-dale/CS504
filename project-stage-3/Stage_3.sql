-- Create a view to identify overdue materials (run after load_data.sql)
CREATE OR REPLACE VIEW overdue_materials AS
SELECT
    b.borrow_id,
    b.material_id,
    m.title,
    b.member_id,
    mem.name         AS member_name,
    mem.contact_info AS member_contact,
    b.staff_id,
    b.due_date,
    CURRENT_DATE - b.due_date AS days_overdue
FROM borrow b
JOIN material m   ON b.material_id = m.material_id
JOIN member_tbl mem ON b.member_id  = mem.member_id
WHERE b.return_date IS NULL
  AND b.due_date < CURRENT_DATE;


-- Log when staff are alerted about an overdue borrow (at most once per borrow per day)
CREATE TABLE overdue_alert_log (
    alert_id      SERIAL PRIMARY KEY,
    borrow_id     INTEGER REFERENCES borrow(borrow_id),
    staff_id      INTEGER REFERENCES staff(staff_id),
    alerted_on    DATE NOT NULL DEFAULT CURRENT_DATE,
    alert_method  TEXT DEFAULT 'email',
    UNIQUE (borrow_id, alerted_on)
);


-- Feature 2: member status and overdue occurrence tracking
ALTER TABLE member_tbl
    ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive'));

-- create overdue occurrences table
CREATE TABLE overdue_occurrences (
    occurrence_id  SERIAL PRIMARY KEY,
    member_id      INTEGER REFERENCES member_tbl(member_id),
    borrow_id      INTEGER REFERENCES borrow(borrow_id) UNIQUE,
    flagged_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

-- create overdue fee payment table
CREATE TABLE fee_payment (
    payment_id    SERIAL PRIMARY KEY,
    member_id     INTEGER REFERENCES member_tbl(member_id),
    paid_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    amount        NUMERIC(8, 2) NOT NULL CHECK (amount > 0),
    staff_id      INTEGER REFERENCES staff(staff_id),
    payment_notes TEXT
);


-- Daily batch: staff alerts + one overdue occurrence row per borrow (Feature 1 + Feature 2)
CREATE OR REPLACE FUNCTION run_daily_overdue_alerts()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    inserted_alerts INTEGER;
BEGIN
    INSERT INTO overdue_alert_log (borrow_id, staff_id, alert_method)
    SELECT om.borrow_id, om.staff_id, 'email'
    FROM overdue_materials om
    WHERE NOT EXISTS (
        SELECT 1
        FROM overdue_alert_log al
        WHERE al.borrow_id = om.borrow_id
          AND al.alerted_on = CURRENT_DATE
    );

    GET DIAGNOSTICS inserted_alerts = ROW_COUNT;

    INSERT INTO overdue_occurrences (member_id, borrow_id, flagged_on)
    SELECT b.member_id, b.borrow_id, CURRENT_DATE
    FROM borrow b
    WHERE b.return_date IS NULL
      AND b.due_date < CURRENT_DATE
      AND NOT EXISTS (
          SELECT 1
          FROM overdue_occurrences oc
          WHERE oc.borrow_id = b.borrow_id
      );

    RETURN inserted_alerts;
END;
$$;


-- deactivate member if 3 or more overdue occurrences exist
CREATE OR REPLACE FUNCTION check_and_deactivate_member()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    occurrence_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO occurrence_count
    FROM overdue_occurrences
    WHERE member_id = NEW.member_id;

    IF occurrence_count >= 3 THEN
        UPDATE member_tbl
        SET status = 'inactive'
        WHERE member_id = NEW.member_id
          AND status = 'active';
    END IF;

    RETURN NEW;
END;
$$;

-- trigger to deactivate member if 3 or more overdue occurrences exist
CREATE TRIGGER trg_deactivate_member
AFTER INSERT ON overdue_occurrences
FOR EACH ROW
EXECUTE FUNCTION check_and_deactivate_member();



-- function to reactivate member after overdue fee payment is recieved
CREATE OR REPLACE FUNCTION check_and_reactivate_member()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    latest_occurrence DATE;
BEGIN
    SELECT MAX(flagged_on) INTO latest_occurrence
    FROM overdue_occurrences
    WHERE member_id = NEW.member_id;

    IF latest_occurrence IS NOT NULL AND NEW.paid_on >= latest_occurrence THEN
        UPDATE member_tbl
        SET status = 'active'
        WHERE member_id = NEW.member_id
          AND status = 'inactive';

        IF FOUND THEN
            DELETE FROM overdue_occurrences
            WHERE member_id = NEW.member_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- trigger to reactivate member after overdue fee payment is recieved
CREATE TRIGGER trg_reactivate_member
AFTER INSERT ON fee_payment
FOR EACH ROW
EXECUTE FUNCTION check_and_reactivate_member();
