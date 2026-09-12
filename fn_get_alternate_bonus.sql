CREATE FUNCTION [dbo].[fn_get_alternate_bonus]
(
@rentabilityid UNIQUEIDENTIFIER -- GUID расчета рентабельности
)
RETURNS DECIMAL(6,2) 
AS 
BEGIN

-- Получаем "БЕ", указанный у ТГ, в которой находится Продукт Тендера
DECLARE @TenderBusinessUnit UNIQUEIDENTIFIER = (SELECT tg.iek_business_unitid -- Сравниваем "БЕ", указанный у ТГ, в которой находится Продукт Тендера
	FROM [CRM_MSCRM].[dbo].[product] as tg 
		JOIN [CRM_MSCRM].[dbo].[product] as prod on tg.productid = prod.iek_parent_product
		JOIN [CRM_MSCRM].[dbo].[opportunityproduct] as opp on prod.productid = opp.productid
	WHERE
		opp.iek_rentabilityid = @rentabilityid)

-- Получаем "БЕ" с названием "УСПЭ МКНС"
DECLARE @CheckedBusinessUnit UNIQUEIDENTIFIER = (SELECT iek_business_unitid
	FROM [CRM_MSCRM].[dbo].[iek_business_unit] 
	WHERE iek_name = 'УСПЭ МКНС')

-- Возвращаем 5%, если БЕ "УСПЭ МКНС", иначе 0%
RETURN IIF(@TenderBusinessUnit = @CheckedBusinessUnit, 5, 0)

END