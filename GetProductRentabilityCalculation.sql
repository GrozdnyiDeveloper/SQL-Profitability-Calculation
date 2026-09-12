USE [IEK_Extensions]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER proc [dbo].[GetProductRenatbilityCalculation]

		@product_code VARCHAR(50),  -- код продукта 1С
		@rentabilityid UNIQUEIDENTIFIER = NULL,   -- GUID рентабельности
		@qnt INT = 0,			-- количество
		@ROUND_qnt DECIMAL (16,6), -- окргул. количество
		@wanted_discount DECIMAL(6,2),  -- желаемая скидки
		@payment_type INT = 0,		   -- тип оплаты 0 - Отсрочка, 1 предоплата
		@regionid UNIQUEIDENTIFIER = NULL,   -- регион guid - для расчера коэфф ДПСЗ
		@additional_delay INT = 0,	   --отсрочка оплаты, дни
		@partner_status nvarchar(200) = null,   -- Статус партнера: Проектный ФСК, Проектный партнер, Без статуса
		@project_status int = null, -- 2 - регистрация, 3 защита
		@check_avg_bonus tinyint = null , -- учитывать при расчете бонуса  0 - не учитывать при расчете, 1 учитывать , null = без учета бонуча - общий коэфициент

		-- параметры для ускорения выполнения запроса  при получении данных для расчета папки

		@product_price  DECIMAL(10,2),   -- цена за продукт из прайс листа
		@product_group NVARCHAR(1024),    -- Группа ДДП - название
		@analitic_direction  NVARCHAR(1024),   -- направление для Аналитики
		@business_unitid varchar(10), -- ID БЕ из внешней БД
		@expense_calculation_type int = 1	-- 1 - по цене, 2 - по себестоимости
AS 
BEGIN 
	IF @wanted_discount >= 100
		SET @wanted_discount = 99.99

	DECLARE @cond_var DECIMAL(8,4),
			@cond_const DECIMAL(8,4),
			@cond_opp DECIMAL(8,4),
			@partner_priceNoNDS DECIMAL(12,4),
			@seflcost_qnt INT,
			@seflcost_sum INT,
			@selfcost_sebestNoNDS DECIMAL (20,13),
			@selfcost_type NVARCHAR(150),
			@default_var_costs DECIMAL(8,4),
			@default_const_costs DECIMAL(8,4),
			@default_opp_costs DECIMAL(8,4),
			@days_in_year INT = DATEDIFF(DAY, getDate() , DateAdd(year,1,getdate())),
			@interest_on_iek_funds_a_year DECIMAL(10,2) = 0, 
			@bonus_percent DECIMAL(6,2) = dbo.fn_get_tender_bonus(@rentabilityid, @project_status, @wanted_discount), -- процент бонуса (только для продуктов Тендера)
			@product_business_unitid varchar(10) = ISNULL(dbo.fn_get_business_unit(@product_code), @business_unitid), -- БЕ продукта из CRM (если пустое, то из внешней БД)
			@current_VAT decimal(3,2) = dbo.fn_get_current_VAT() -- получаем текущий НДС (20% до начала 2026 г, 22% после)
	
	-- Получить ставку за пользование заемными средствами IEK в год, % (если указан срок дополнительной острочки @additional_delay)
	IF @additional_delay > 0
		SELECT TOP(1) @interest_on_iek_funds_a_year = CAST([iek_value] AS DECIMAL) FROM [CRM_MSCRM].[dbo].[iek_settingsBase] (nolock) WHERE [iek_name] = 'INTEREST_ON_BORROWED_FUNDS_IEK'

	SELECT @default_var_costs = IIF(@bonus_percent IS NOT NULL AND vc.iek_variable_costs_no_bonus IS NOT NULL, iek_variable_costs_no_bonus, vc.iek_variable_costs),
		@default_const_costs = vc.iek_fixed_costs,
		@default_opp_costs = vc.iek_opportunity_costs
	FROM 
		[CRM_MSCRM].[dbo].[iek_costs_for_rentabilityBase] vc (NOLOCK)
	WHERE 
		vc.iek_direction = 'Default' 
		AND vc.statecode = 0
		AND (vc.iek_region = @regionid OR (@regionid IS NULL AND vc.iek_region IS NULL))


	IF (EXISTS(select 1 from [CRM_MSCRM].[dbo].[iek_costs_for_rentabilityBase] (NOLOCK)  vc
		join [CRM_MSCRM].[dbo].[iek_business_unit] (nolock) bu on bu.iek_business_unitId = vc.iek_business_unitid
	WHERE 
		bu.iek_mdm_id = @product_business_unitid
		AND vc.statecode = 0
		AND (vc.iek_region = @regionid OR (@regionid IS NULL AND vc.iek_region IS NULL)))
	)
	BEGIN
		SELECT @cond_var = IIF(@bonus_percent IS NOT NULL, IIF(vc.iek_variable_costs_no_bonus IS NOT NULL, vc.iek_variable_costs_no_bonus/100, NULL), ISNULL(dbo.fn_get_varcosts(vc.iek_variable_costs, vc.iek_bonus_costs, @partner_status, @project_status, @wanted_discount, @check_avg_bonus), @default_var_costs)/100)
			, @cond_const = ISNULL(vc.iek_fixed_costs, @default_const_costs)/100
			, @cond_opp =  ISNULL(vc.iek_opportunity_costs, @default_opp_costs)/100 
		FROM [CRM_MSCRM].[dbo].[iek_costs_for_rentabilityBase] (NOLOCK)  vc
			join [CRM_MSCRM].[dbo].[iek_business_unit] (nolock) bu on bu.iek_business_unitId = vc.iek_business_unitid
		WHERE
			bu.iek_mdm_id = @product_business_unitid
			AND vc.statecode = 0
			AND (vc.iek_region = @regionid OR (@regionid IS NULL AND vc.iek_region IS NULL))

		IF (@bonus_percent IS NOT NULL AND @cond_var IS NULL)
		BEGIN
			RAISERROR('Некорректные данные расходов по продукту Тендера: для найденной записи расходов не заданы "Расходы в выручке склада и доставки"',16,1)
		END
	END
	ELSE 
	BEGIN
		IF (EXISTS(select 1 from [CRM_MSCRM].[dbo].[iek_costs_for_rentabilityBase] (NOLOCK)  vc
		WHERE
			vc.iek_direction = @analitic_direction 
			AND vc.statecode = 0
			AND (vc.iek_region = @regionid OR (@regionid IS NULL AND vc.iek_region IS NULL)))
		)
		BEGIN
			SELECT @cond_var = IIF(@bonus_percent IS NOT NULL, ISNULL(vc.iek_variable_costs_no_bonus, ISNULL(vc.iek_variable_costs, @default_var_costs)), ISNULL(dbo.fn_get_varcosts(vc.iek_variable_costs, vc.iek_bonus_costs, @partner_status, @project_status, @wanted_discount, @check_avg_bonus), @default_var_costs))/100
			, @cond_const = ISNULL(vc.iek_fixed_costs, @default_const_costs)/100
			, @cond_opp =  ISNULL(vc.iek_opportunity_costs, @default_opp_costs)/100 
		FROM [CRM_MSCRM].[dbo].[iek_costs_for_rentabilityBase] (NOLOCK)  vc
		WHERE 
			vc.iek_direction  = @analitic_direction 
			AND vc.statecode = 0
			AND (vc.iek_region = @regionid OR (@regionid IS NULL AND vc.iek_region IS NULL))
		END
		ELSE
		BEGIN
			SELECT @cond_var = @default_var_costs/100
				, @cond_const = @default_const_costs/100
				, @cond_opp = @default_opp_costs/100 
		END
	END

	 -- CRM-2918
	 -- партнерская цена
		-- по умолчанию
	SELECT @partner_priceNoNDS = ROUND(CASE 
										WHEN @product_group like '20.%' 
										THEN  @product_price*0.6/@current_VAT
										WHEN @product_group like '30.%' 
										THEN  @product_price*0.5/@current_VAT
										WHEN @product_group like '31.%' 
										THEN  @product_price*0.5/@current_VAT
										ELSE @product_price*0.49/@current_VAT END,2)

	   -- для обычных продаж из аналитики
	SELECT @partner_priceNoNDS =  round(@product_price*(1-СкидкаОсновная)/@current_VAT, 2) 
	  FROM DiscountModel t
	WHERE t.Подгруппа = @product_group	

	   --Для проектых продаж 
	IF @partner_status IS NOT NULL 
		BEGIN
			SELECT @partner_priceNoNDS = ROUND(@product_price*(1 - СкидкаИтого)/@current_VAT, 2)
			  FROM DiscountModel t
			WHERE t.Подгруппа = @product_group
		END

	SELECT @seflcost_qnt = self_cost.QuantitySold,
		   @seflcost_sum = self_cost.SumSold,
		   @selfcost_sebestNoNDS = [СебЕд_без НДС_руб] ,
		   @selfcost_type = [ТипСебестоимости]
	FROM 
		selfcostmodel self_cost WITH (NOLOCK) 
	WHERE 
		self_cost.КодНоменклатуры = @product_code

	;WITH raw_data AS (
		SELECT @ROUND_qnt rountQnt
			 , @product_code ProductCode
			 , -(an.[МинОстаток]-@qnt) AS min2
			 , CASE 
			   WHEN  -(an.[МинОстаток]-@qnt) >0 
			   THEN  -(an.[МинОстаток]-@qnt)
			   ELSE 0 
			   END AS max2
			 , an.[Лимит] [Лимит]
			 , NULL iek_ns
			 , an.[Страна]  [Страна]  
			 , ROUND(ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/@current_VAT),2)  AS [РасходнаяЦенаRUR]
			 , ISNULL(@selfcost_sebestNoNDS, ROUND(0,2)) AS [СебЕд_без НДС_руб] -- CRM-555042 Заменил ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/1.2) на 0, для не подстановки расходной цены без НДС
			 , CASE 
			   WHEN @selfcost_sebestNoNDS is NULL 
			   THEN CAST(0 AS bit) 
			   ELSE CAST(1 AS bit) 
			   END AS [Себестоимость Определена]
			 , ROUND(@product_price/@current_VAT * (1- 
				(CASE 
				 WHEN @payment_type=279750001 
				 THEN (@wanted_discount-1.5) 
				 ELSE @wanted_discount
				 END)/100
				 ) * @ROUND_qnt,2) AS [Выручка В ТЦ без НДС]
			 , IIF (@bonus_percent IS NOT NULL, ROUND(((@product_price/@current_VAT * (1-@wanted_discount/100)) * (@bonus_percent/100) + @cond_var * @partner_priceNoNDS) * @ROUND_qnt, 2), -- CRM-609665 Добавил учет бонусов (из CRM) партнеров в расчете R2 по Тендеру
					case 
					when @check_avg_bonus = 1 
					then ROUND(dbo.fn_get_fskvarcostVal(@partner_priceNoNDS, @product_price, @partner_status, @wanted_discount, @cond_var) * @ROUND_qnt, 2) --см http://helpdesk.iek.local/Task/View/530101
					else IIF(@expense_calculation_type = 1,
							ROUND(ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/@current_VAT) * @cond_var * @ROUND_qnt, 2),
							ROUND(ISNULL(@selfcost_sebestNoNDS, ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/@current_VAT)) * @cond_var * @ROUND_qnt, 2)
						)
					end
			   ) AS [Усл перем расх]
			 , IIF(@expense_calculation_type = 1,
					ROUND(ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/@current_VAT) * @cond_const * @ROUND_qnt, 2),
					ROUND(ISNULL(@selfcost_sebestNoNDS, ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/@current_VAT)) * @cond_const * @ROUND_qnt, 2)
			   ) AS [Усл пост расх]
			 , IIF(@expense_calculation_type = 1,
					ROUND(ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/@current_VAT) * @cond_opp * @ROUND_qnt, 2),
					ROUND(ISNULL(@selfcost_sebestNoNDS, ISNULL(@partner_priceNoNDS, an.[РасходнаяЦенаRUR]/@current_VAT)) * @cond_opp * @ROUND_qnt, 2)
			   ) AS [Вменен расх]
			 , @cond_opp AS [Вменен_расх_Val]
			 , @cond_var AS  [Усл перем расх_Val]
			 , @cond_const AS [Усл пост расх_Val]
			 , @selfcost_type AS [CostType]
		FROM 
			[CRMPriceModel] (NOLOCK) an --22,03,2023 АК заменено на кешированную [SYCORAX].[Analitics].[dbo].[CRMPriceModel] an
		WHERE 
			an.[КодНоменклатуры] = @product_code 
	  -- AND (
			--    (an.[НеВключатьВПрайс]='Нет' AND an.[Включать в планы ИЭК-Россия]=1)   -- этого условия нет в тендерах, но есть в спецценах - не понятно включать или нет
			--  or @payment_type = 279750001)
			)
		, NC_data AS (
		SELECT CAST(
				(CASE 
				 WHEN [Лимит] is NULL or max2 is NULL THEN 0
				 WHEN [Лимит]           <= max2 AND [Лимит]<=@ROUND_qnt THEN [Лимит]
				 WHEN @ROUND_qnt<= max2 AND @ROUND_qnt<=[Лимит] THEN @ROUND_qnt
				 ELSE max2
				 END)* [РасходнаяЦенаRUR] 
			AS DECIMAL(16,2)) AS NC
			,*
			, ROUND([Выручка В ТЦ без НДС] * @interest_on_iek_funds_a_year / 100 * @additional_delay / @days_in_year, 2) AS [Расх за доп отсрочку]
		FROM raw_data
		)
		,correction_data AS
		(
		SELECT CASE 
			   WHEN [Страна] not in ('Россия','Собственные заводы') AND  NC > 0 AND NC<=500000 THEN 0.01
			   WHEN [Страна] not in ('Россия','Собственные заводы') AND  NC > 500000 THEN 0.09
			   ELSE 0 END AS [Корректировка_МП]
		,*
		FROM NC_data
		)
		,revenue_data AS
		(
		SELECT 	
			@product_code [Код продукта],
			[РасходнаяЦенаRUR],
			NC,
			[Корректировка_МП],
			[Выручка В ТЦ без НДС],	
			[СебЕд_без НДС_руб],
			[Себестоимость Определена],
			[Усл перем расх],
			[Усл пост расх],
			[Вменен расх],
			ROUND([Выручка В ТЦ без НДС]*(1-[Корректировка_МП]) - [СебЕд_без НДС_руб]*@ROUND_qnt,2) AS [Валовая Прибыль без НДС],
			ROUND([Выручка В ТЦ без НДС]*(1-[Корректировка_МП]) - [СебЕд_без НДС_руб]*@ROUND_qnt -[Усл перем расх],2)  AS [Мар прибыль без НДС],
			ROUND([Выручка В ТЦ без НДС]*(1-[Корректировка_МП]) - [СебЕд_без НДС_руб]*@ROUND_qnt -[Усл перем расх] - [Усл пост расх] - [Расх за доп отсрочку],2) AS [Прибыль от продаж без НДС],
			ROUND([Выручка В ТЦ без НДС]*(1-[Корректировка_МП]) - [СебЕд_без НДС_руб]*@ROUND_qnt - [Усл перем расх] - [Усл пост расх] - [Расх за доп отсрочку] - [Вменен расх],2) AS [Прибыль вменен без НДС],
			[Лимит], 
			max2,
			min2,
			[Усл перем расх_Val],
			[Усл пост расх_Val],
			[Вменен_расх_Val],
			[Страна],
			[CostType],
			[Расх за доп отсрочку]
		FROM 
			correction_data
		)	

		SELECT [Код продукта],
				CAST(ROUND([Усл перем расх], 2) AS DECIMAL(16,2)) AS [Усл перем расх],
				CAST(ROUND([Усл пост расх], 2) AS DECIMAL(16,2)) AS [Усл пост расх],
				CAST(ROUND([Вменен расх], 2) AS DECIMAL(16,2)) AS [Вменен расх],
				CAST(NC AS DECIMAL(16, 2)) AS [НС],
				CAST([Корректировка_МП] AS DECIMAL(16, 2)) AS [Корректировка_МП],
				[Себестоимость Определена],
				[РасходнаяЦенаRUR],
				CAST(ROUND([СебЕд_без НДС_руб], 2) AS DECIMAL(16,2)) AS [СебЕд_без НДС руб],
				CAST([Выручка В ТЦ без НДС] AS DECIMAL(16,2)) AS [Выручка В ТЦ без НДС],
				CAST([Валовая Прибыль без НДС] AS DECIMAL(16,2)) AS [Валовая Прибыль без НДС],
				CAST([Мар прибыль без НДС] AS DECIMAL(16,2)) AS [Мар прибыль без НДС],
				CAST([Прибыль от продаж без НДС] AS DECIMAL(16,2)) AS [Прибыль от продаж без НДС],
				CAST([Прибыль вменен без НДС] AS DECIMAL(16,2)) AS [Прибыль вменен без НДС],
				CASE WHEN [Выручка В ТЦ без НДС] > 0 THEN CAST([Валовая Прибыль без НДС]/[Выручка В ТЦ без НДС] AS DECIMAL(16,2)) ELSE NULL END AS R1,
				CASE WHEN [Выручка В ТЦ без НДС] > 0 THEN CAST([Мар прибыль без НДС]/[Выручка В ТЦ без НДС] AS DECIMAL(16,2)) ELSE NULL END AS R2,
				CASE WHEN [Выручка В ТЦ без НДС] > 0 THEN CAST([Прибыль от продаж без НДС]/[Выручка В ТЦ без НДС] AS DECIMAL(16,2)) ELSE NULL END AS R3,
				CASE WHEN [Выручка В ТЦ без НДС] > 0 THEN CAST([Прибыль вменен без НДС]/[Выручка В ТЦ без НДС] AS DECIMAL(16,2)) ELSE NULL END AS R3opp,
				[Лимит], 
				max2,
				min2,
				[Усл перем расх_Val],
				[Усл пост расх_Val],
				[Вменен_расх_Val],
				[Страна],
				[CostType],
				CAST([Расх за доп отсрочку] AS DECIMAL(16,2)) AS [Расх за доп отсрочку]
		FROM revenue_data;
END
