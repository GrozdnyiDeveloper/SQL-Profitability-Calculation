CREATE FUNCTION [dbo].[fn_get_business_unit]
(
	@product_code VARCHAR(50) -- код продукта 1С
)
RETURNS VARCHAR(10) 
AS 
BEGIN
	DECLARE @product_id UNIQUEIDENTIFIER,
	@product_type INT,
	@product_business_unitid VARCHAR(10)

	-- Получаем текущий продукт и его тип по коду из CRM
	SELECT TOP 1 @product_type = producttypecode, @product_id = productid
	FROM [CRM_MSCRM].[dbo].[product]
	WHERE iek_product_code = @product_code

	-- В зависимости от Типа текущего продукта получаем БЕ
	IF (@product_type = 279750001) -- Если продукт Номенклатура
	BEGIN
		-- Получаем БЕ из товарной группы текущего продукта
		SELECT @product_business_unitid = bu.iek_mdm_id 
		FROM [CRM_MSCRM].[dbo].[product] as tg 
			JOIN [CRM_MSCRM].[dbo].[product] as prod on tg.productid = prod.iek_parent_product
			JOIN [CRM_MSCRM].[dbo].[iek_business_unit] as bu on tg.iek_business_unitid = bu.iek_business_unitId
		WHERE prod.productid = @product_id 
	END
	ELSE
	BEGIN
		IF (@product_type = 279750001) -- Если продукт Группа товаров
		BEGIN
			-- Получаем БЕ из самой товарной группы
			SELECT @product_business_unitid = bu.iek_mdm_id 
			FROM [CRM_MSCRM].[dbo].[product] prod
				JOIN [CRM_MSCRM].[dbo].[iek_business_unit] as bu on bu.iek_business_unitId = prod.iek_business_unitid
			WHERE productid = @product_id 
		END
	END

	RETURN @product_business_unitid
END