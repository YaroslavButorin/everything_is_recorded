-- Задание 1
CREATE OR REPLACE PROCEDURE update_employees_rate(data json)
LANGUAGE plpgsql
AS $$
DECLARE
    employee_record json;
    employee_id uuid;
    rate_change integer;
	new_rate integer;
	min_rate integer := 500;
BEGIN
    FOR employee_record IN SELECT * FROM jsonb_array_elements(data::jsonb)
    LOOP
        -- Извлекаем идентификатор сотрудника и процент изменения
        employee_id := (employee_record->>'employee_id')::uuid;
        rate_change := (employee_record->>'rate_change')::integer;
		
		-- Проверяем новую ставку
		SELECT rate + (rate * rate_change / 100) INTO new_rate
        FROM employees
        WHERE id = employee_id;

		IF new_rate < min_rate THEN
            new_rate := min_rate;
        END IF;
		
        
        -- Обновляем ставку сотрудника
        UPDATE employees
        SET rate = new_rate
        WHERE id = employee_id;
        
        -- Логирование
        RAISE NOTICE 'Ставка сотрудника с ID % обновлена на % процентов', employee_id, rate_change;
    END LOOP;
END;
$$;
-- Задание 2
CREATE OR REPLACE PROCEDURE indexing_salary(p integer)
LANGUAGE plpgsql
AS $$
DECLARE
    avg_rate numeric;
BEGIN
    -- Вычисляем среднюю зарплату до индексации
    SELECT AVG(rate) INTO avg_rate FROM employees;
    
    -- Обновляем зарплаты сотрудников
    UPDATE employees
    SET rate = ROUND(rate * CASE 
                                WHEN rate < avg_rate THEN (1 + (p + 2) / 100.0)
                                ELSE (1 + p / 100.0)
                            END);
    -- Логирование
    RAISE NOTICE 'Индексация зарплат завершена. Процент индексации: %, дополнительный процент для сотрудников с зарплатой ниже средней: %', p, p + 2;
END;
$$;

-- Задание 3
CREATE OR REPLACE PROCEDURE close_project(p_project_id uuid)
LANGUAGE plpgsql
AS $$
DECLARE
    project RECORD;
    total_worked_hours integer;
    saved_hours integer;
    bonus_hours_per_member integer;
    num_members integer;
BEGIN
    -- Проверяем, существует ли проект и открыт ли он
    SELECT * INTO project
    FROM projects
    WHERE id = p_project_id AND is_active = true;
    
    -- Если нет
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Проект не найден или уже закрыт.';
    END IF;

    RAISE NOTICE 'Проект найден и открыт.';

    -- Закрываем проект
    UPDATE projects
    SET is_active = false
    WHERE id = p_project_id;
    
    -- Если estimated_time не задано, выходим
    IF project.estimated_time IS NULL THEN
        RAISE NOTICE 'Estimated_time не задано. Завершение процедуры.';
        RETURN;
    END IF;

    -- Вычисляем суммарное количество отработанных часов по проекту
    SELECT COALESCE(SUM(work_hours), 0) INTO total_worked_hours,
           COUNT(DISTINCT(employee_id)) INTO num_members
    FROM logs
    WHERE project_id = p_project_id;

    -- Если отработанных часов нет, выходим
    IF total_worked_hours = 0 THEN
        RAISE NOTICE 'Отработанных часов нет. Завершение процедуры.';
        RETURN;
    END IF;

    saved_hours := project.estimated_time - total_worked_hours;
    IF saved_hours <= 0 THEN
        RAISE NOTICE 'Сэкономленных часов нет. Завершение процедуры.';
        RETURN;
    END IF;
    
    -- Если участников нет, выходим
    IF num_members = 0 THEN
        RAISE NOTICE 'Участников нет. Завершение процедуры.';
        RETURN;
    END IF;

    -- Вычисляем количество бонусных часов на участника
    bonus_hours_per_member := FLOOR((saved_hours * 0.75) / num_members);
    
    -- Бонусные часы не должны превышать 16 часов на сотрудника
    IF bonus_hours_per_member > 16 THEN
        bonus_hours_per_member := 16;
    END IF;

    -- Распределяем бонусные часы и записываем их в логи
    INSERT INTO logs (employee_id,project_id,work_date,work_hours)
    SELECT DISTINCT(employee_id),project_id,CURRENT_DATE,bonus_hours_per_member
    FROM logs
    WHERE project_id = p_project_id;

    -- Логирование завершения
    RAISE NOTICE 'Проект с ID % успешно закрыт. Начислено бонусных часов: % на каждого из % участников.', 
                 p_project_id, bonus_hours_per_member, num_members;
END;
$$;

-- Задание 4
CREATE OR REPLACE PROCEDURE log_work(
                                        p_employee_id uuid,
                                        p_project_id uuid,
                                        p_work_date date,
                                        p_worked_hour integer)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Проверяем, существует ли проект и открыт ли он
    PERFORM 1 
    FROM projects
    WHERE id = p_project_id AND is_active = true;

    -- Если нет
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Project closed';
        RETURN;
    END IF;

    RAISE NOTICE 'Проект найден и открыт.';
    
    -- Проверяем колличество часов
    IF p_worked_hour < 1 OR p_worked_hour > 24 THEN
        RAISE EXCEPTION 'Некорректное колличество часов, процедура остановленна';
        RETURN;
    END IF;
    RAISE NOTICE 'Часы работы получены.';

    INSERT INTO logs (employee_id, project_id, work_date, work_hours,required_review)
    VALUES (p_employee_id, p_project_id, p_work_date, p_worked_hour,
            CASE
                WHEN p_worked_hour > 16 THEN true
                WHEN p_work_date > CURRENT_DATE THEN true
                WHEN p_work_date < CURRENT_DATE - INTERVAL '7 days' THEN true
                ELSE false
            END);
    RAISE NOTICE 'Запись успешно внесена в логи.';

END;
$$;
-- Задание 5
CREATE TABLE employee_rate_history (
    id serial PRIMARY KEY,
    employee_id uuid NOT NULL,
    rate integer NOT NULL,
    from_date date NOT NULL,
    FOREIGN KEY (employee_id) REFERENCES public.employees(id)
);

INSERT INTO employee_rate_history (employee_id, rate, from_date)
SELECT id, rate, '2020-12-26'
FROM employees;

CREATE OR REPLACE FUNCTION save_employee_rate_history()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO employee_rate_history (employee_id, rate, from_date)
    VALUES (NEW.id, NEW.rate, CURRENT_DATE);
    RETURN NEW;
END;
$$ 
LANGUAGE plpgsql;

CREATE TRIGGER change_employee_rate
AFTER INSERT OR UPDATE OF rate ON employees
FOR EACH ROW
EXECUTE FUNCTION save_employee_rate_history();
-- Задание 6
CREATE OR REPLACE FUNCTION best_project_workers(p_project_id uuid)
RETURNS TABLE(employee text, work_hours INTEGER) AS $$
BEGIN
    RETURN QUERY
    SELECT sub.employee_name, sub.total_hours
    FROM (
        SELECT e.name AS employee_name, 
               SUM(l.work_hours)::INTEGER AS total_hours,
               COUNT(DISTINCT l.work_date) AS work_days
        FROM logs l
        JOIN employees e ON l.employee_id = e.id
        WHERE l.project_id = p_project_id
        GROUP BY e.name
        ORDER BY total_hours DESC, work_days DESC, RANDOM()
        LIMIT 3
    ) sub;
END;
$$ LANGUAGE plpgsql;

-- Задание 7
CREATE OR REPLACE FUNCTION calculate_month_salary(p_begin_date date,p_end_date date)
RETURNS TABLE(employee_id uuid, employee_name text,worked_hours integer,salary numeric) AS $$
BEGIN
    RETURN QUERY
    WITH total_hours AS (
        SELECT 
            l.employee_id,
            e.name,
            e.rate,
            SUM(l.work_hours) AS total_work_hours
        FROM logs l
        JOIN employees e ON l.employee_id = e.id
        WHERE l.created_at BETWEEN p_begin_date AND p_end_date
        AND l.required_review IS false 
        AND l.is_paid IS false
        GROUP BY l.employee_id, e.name, e.rate
    )
    SELECT
        th.employee_id,
        th.name,
        th.total_work_hours::integer AS worked_hours,
        (LEAST(th.total_work_hours, 160) * th.rate + 
        GREATEST(th.total_work_hours - 160, 0) * th.rate * 1.25) AS salary
    FROM total_hours th;

END;
$$ LANGUAGE plpgsql;

