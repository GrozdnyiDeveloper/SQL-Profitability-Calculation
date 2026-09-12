USE [IEK_Extensions]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER proc [dbo].[GetProductRentabilty]

		@product_code VARCHAR(50),
		@rentabilityid UNIQUEIDENTIFIER = NULL,
		@qnt INT = 0,
		@ROUND_qnt DECIMAL (16,6) ,
		@wanted_discount DECIMAL(6,2),
		@payment_type INT = 0,
		@regionid UNIQUEIDENTIFIER = NULL,
		@additional_delay INT = 0,	
		@partner_status nvarchar(200) = null,
		@project_status int = null,			-- 2 - регистрация, 3 - защита
		@expense_calculation_type int = 1,	-- 1 - по цене, 2 - по себестоимости
		@check_avg_bonus tinyint = null  --1 - учитывать, 0 не учитывать -- учитывать в расчете бонуса, null - без учета боуса - общий коэффициент

AS
BEGIN
			
		
	DECLARE @product_group nvarchar(1000),
			@analitic_direction nvarchar(1000),
			@business_unitid varchar(10), 
			@costPrice DECIMAL(10,2)
	
	SELECT 	
			@analitic_direction = ddp.[Направление аналитики],
			@business_unitid = cast(ddp.[БЕ ID] as varchar(10)),
			@product_group = ddp.[Подгруппа]
	FROM	[SERVER].[DB].[Обмены CRM].[Продукт.Продукт] pr
		    JOIN [SERVER].[DB].[Обмены CRM].[Продукт.ДДП] ddp on ddp.[ДДП ID] = pr.[ДДП ID]
		    JOIN [SERVER].[DB].[Обмены CRM].[Продукт.БЕ] be on be.[БЕ ID] = ddp.[БЕ ID]
	WHERE	pr.[Код 1C] = @product_code
			AND pr.[Код 1C] IS NOT NULL
			AND pr.[Дата удаления из ассортимента] IS NULL

	SELECT TOP 1 @costPrice = pr.price
	FROM	[CRM_MSCRM].[dbo].[product] pr 
	WHERE	pr.iek_product_code = @product_code

	EXEC IEK_Extensions.dbo.GetProductRenatbilityCalculation 
			@product_code = @product_code,
			@rentabilityid = @rentabilityid,
			@qnt = @qnt,
			@round_qnt = @round_qnt,
			@wanted_discount = @wanted_discount,
			@payment_type = @payment_type,
			@regionid = @regionid,
			@additional_delay = @additional_delay,
			@partner_status = @partner_status,
			@project_status = @project_status,
			@product_price = @costPrice,
			@product_group = @product_group,
			@check_avg_bonus = @check_avg_bonus,
			@business_unitid = @business_unitid, 
			@analitic_direction = @analitic_direction,
			@expense_calculation_type = @expense_calculation_type
END
