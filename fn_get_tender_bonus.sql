CREATE FUNCTION [dbo].[fn_get_tender_bonus]
(
@rentabilityid UNIQUEIDENTIFIER = NULL, -- GUID расчета рентабельности
@project_status int = null, -- 2 - регистрация, 3 защита
@wanted_discount DECIMAL(6,2)  -- желаемая скидки
)
RETURNS DECIMAL(6,2) 
AS 
BEGIN
	-- Если не указан ID Расчета рентабельности
	IF @rentabilityid IS NULL
	BEGIN
		RETURN NULL
	END
	
	-- Производим поиск Продукта тендера
	DECLARE @tenderId UNIQUEIDENTIFIER = (SELECT 
		OpportunityId 
	FROM 
		[CRM_MSCRM].[dbo].[opportunityproduct] (NOLOCK)
	WHERE 
		iek_rentabilityid = @rentabilityid)

	-- Если не нашли Продукт тендера возвращаем NULL 
	IF @tenderId IS NULL
	BEGIN
		RETURN NULL
	END

	-- Производим поиск Тендера и получаем Партнера
	DECLARE @partnerId UNIQUEIDENTIFIER = (SELECT 
		customerid
	FROM 
		[CRM_MSCRM].[dbo].[opportunity] (NOLOCK)
	WHERE 
		opportunityid = @tenderId)
	

	-- Если не нашли Тендер/Партнера возвращаем NULL 
	IF @partnerId IS NULL
	BEGIN
		RETURN NULL
	END

	-- Производим поиск Головного партнера для найденного Партнера через цикл
	DECLARE @parentPartnerId UNIQUEIDENTIFIER;
	WHILE 1 = 1
	BEGIN
		-- Получаем Головную компанию для текущего Партнера
		SELECT @parentPartnerId = parentaccountid
		FROM [CRM_MSCRM].[dbo].[Account]
		WHERE accountid = @partnerId;
    
		-- Если Головная компания пустая, то выходим из цикла
		IF @parentPartnerId IS NULL
			BREAK;
    
		-- Устанавливаем Головного партнера в качестве текущего
		SET @partnerId = @parentPartnerId;
	END

	-- Производим поиск Комерческих условий
	DECLARE @conditionId UNIQUEIDENTIFIER = (SELECT 
		iek_commercial_conditionsId
	FROM 
		[CRM_MSCRM].[dbo].[iek_commercial_conditions] (NOLOCK)
	WHERE 
		iek_accountid = @partnerId		 -- Партнер
		AND iek_period = YEAR(GETDATE()) -- Текущий год
		AND statuscode = 279750006
		AND statecode = 0)		 -- Отправлено в 1C 
	

	-- Если не нашли Комерческих условий возвращаем функцию fn_get_alternate_bonus 
	IF @conditionId IS NULL
	BEGIN
		RETURN dbo.fn_get_alternate_bonus(@rentabilityid)
	END
	
	-- Производим поиск КУ. Дополнительная бонусная программа с нужным типом
	DECLARE @bonusProgramId UNIQUEIDENTIFIER = (SELECT 
		iek_commercial_condition_bonusprogramid
	FROM 
		[CRM_MSCRM].[dbo].[iek_commercial_condition_bonusprogram] (NOLOCK) ccbp
		JOIN [CRM_MSCRM].[dbo].[iek_bonusprogram] bp on ccbp.iek_bonusprogramid = bp.iek_bonusprogramid
		JOIN [CRM_MSCRM].[dbo].[iek_bonus_program_category] bpc on bpc.iek_bonus_program_categoryid = bp.iek_bonus_programm_category
	WHERE 
		iek_commercial_conditionid = @conditionId
		AND bpc.iek_code = 'PROJECT_DISTR'
		AND ccbp.statecode = 0)

	-- Если не нашли КУ. Дополнительная бонусная программа возвращаем функцию fn_get_alternate_bonus 
	IF @conditionId IS NULL
	BEGIN
		RETURN dbo.fn_get_alternate_bonus(@rentabilityid)
	END

	-- Получаем сумму Продукта тендера
	DECLARE @ProductSum DECIMAL(18,2) = (SELECT iek_sum
	FROM [CRM_MSCRM].[dbo].[opportunityproduct] (NOLOCK)
	WHERE iek_rentabilityid = @rentabilityid)
	
	DECLARE @Bonuses TABLE (
		RowNum INT IDENTITY(1,1),
		Id UNIQUEIDENTIFIER,
		Type INT,
		BU UNIQUEIDENTIFIER,
		Condition INT,
		Discount DECIMAL(6,2),
		Summ DECIMAL(18,2),
		Bonus DECIMAL(6,2)
	);

	-- Производим поиск всех Условий бонусов
	INSERT INTO 
		@Bonuses (Id, Type, BU, Condition, Discount, Summ, Bonus)
	SELECT 
		iek_cc_patner_bonusid, iek_status_typecode, iek_business_unitid, 
		iek_conditioncode, iek_discount, iek_sum, iek_bonus_percent
	FROM 
		[CRM_MSCRM].[dbo].[iek_cc_patner_bonus]
	WHERE 
		iek_commercial_condition_bonusprogramid = @bonusProgramId
		AND statecode = 0
	ORDER BY iek_status_typecode;

	DECLARE @MaxRow INT, 
			@CurrentRow INT,
			@CurrentType INT,
			@CurrentBU UNIQUEIDENTIFIER,
			@CurrentCondition INT,
			@CurrentDiscount DECIMAL(6,2),
			@CurrentSumm DECIMAL(18,2),
			@CurrentBonus DECIMAL(6,2);

	SELECT @CurrentRow = MIN(RowNum), @MaxRow = MAX(RowNum) FROM @Bonuses;

	-- Производим проверку по всем найденным Условиям бонусов
	WHILE @CurrentRow <= @MaxRow
	BEGIN
		-- Получаем данные Условия
		SELECT @CurrentType = Type, 
			   @CurrentBU = BU, 
			   @CurrentCondition = Condition,
			   @CurrentDiscount = Discount,
			   @CurrentSumm = Summ,
			   @CurrentBonus = Bonus
		FROM @Bonuses 
		WHERE RowNum = @CurrentRow;

		-- Производим проверку Условий
		DECLARE @TypeCheck BIT = CASE @CurrentType
			WHEN 279750000 -- Тип "Для БЕ"
			THEN IIF(EXISTS(SELECT tg.iek_business_unitid -- Сравниваем "БЕ", указанный у ТГ, в которой находится Продукт Тендера
				FROM [CRM_MSCRM].[dbo].[product] as tg 
					JOIN [CRM_MSCRM].[dbo].[product] as prod on tg.productid = prod.iek_parent_product
					JOIN [CRM_MSCRM].[dbo].[opportunityproduct] as opp on prod.productid = opp.productid
				WHERE
					opp.iek_rentabilityid = @rentabilityid 
					AND tg.iek_business_unitid = @CurrentBU), 'true', 'false')
			WHEN 279750001 -- Тип "Бонус при регистрации"
			THEN IIF(@project_status = 2, 'true', 'false') -- Проверяем, что "Статус проекта" = "Регистрация"
			WHEN 279750002 -- Тип "Бонус при защите"
			THEN IIF(@project_status = 3, 'true', 'false') -- Проверяем, что "Статус проекта" = "Защита"
			WHEN 279750003 -- Тип "Без статуса"
			THEN IIF(@project_status = 0, 'true', 'false') -- Проверяем, что "Статус проекта" = "Отсутствует"
			WHEN 279750004 -- Тип "% от цены партнера"
			THEN 'true' -- Проходит по умолчанию
			ELSE 'false' -- Иначе отклоняется
		END	

		-- Если проерка на тип не пройдена, то переходим к следующему условию
		IF @TypeCheck = 'false'
		BEGIN
			SET @CurrentRow = @CurrentRow + 1;
			CONTINUE
		END
	
		-- Производим проверку Скидки
		DECLARE @DiscountCheck BIT = CASE @CurrentCondition
			WHEN 279750000 -- Больше или равно
			THEN IIF(@wanted_discount >= @CurrentDiscount OR @CurrentDiscount IS NULL, 'true', 'false')
			WHEN 279750001 -- Больше
			THEN IIF(@wanted_discount > @CurrentDiscount OR @CurrentDiscount IS NULL, 'true', 'false')
			WHEN 279750002 -- Меньше
			THEN IIF(@wanted_discount < @CurrentDiscount OR @CurrentDiscount IS NULL, 'true', 'false')
			ELSE 'true'
		END

		-- Если проерка на скидку не пройдена, то переходим к следующему условию
		IF @DiscountCheck = 'false'
		BEGIN
			SET @CurrentRow = @CurrentRow + 1;
			CONTINUE
		END
		
		-- Производим проверку Скидки
		DECLARE @SumCheck BIT = CASE @CurrentCondition
			WHEN 279750000 -- Больше или равно
			THEN IIF(@ProductSum >= @CurrentSumm OR @CurrentSumm IS NULL, 'true', 'false')
			WHEN 279750001 -- Больше
			THEN IIF(@ProductSum > @CurrentSumm OR @CurrentSumm IS NULL, 'true', 'false')
			WHEN 279750002 -- Меньше
			THEN IIF(@ProductSum < @CurrentSumm OR @CurrentSumm IS NULL, 'true', 'false')
			ELSE 'true'
		END

		-- Если проерка на сумму не пройдена, то переходим к следующему условию
		IF @SumCheck = 'false'
		BEGIN
			SET @CurrentRow = @CurrentRow + 1;
			CONTINUE
		END
	
		-- При прохождении всех проверок возвращаем "Процент бонуса" из текущего условия
		RETURN @CurrentBonus
	END

	-- Если ни одно условие не прошло, возвращаем fn_get_alternate_bonus
	RETURN dbo.fn_get_alternate_bonus(@rentabilityid)
END