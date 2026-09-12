USE [IEK_Extensions]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER proc [dbo].[GetProductSetRentabilty]		
		@rentabilityid UNIQUEIDENTIFIER = NULL,
		@wanted_discount decimal(6,2),
		@payment_type int ,
		@sum_set decimal (14,4),  -- сумма для набора продуктов
		@product_code_set varchar(max) ,  -- набор продуктов строка - список кодов через запятую ('00033761,00033762,00033763,00033764,00033892')
		@regionid uniqueidentifier = null,
		@check_avg_bonus int = null,
		@partner_status nvarchar(200) = null
as
begin
	declare @qnt int =  null,
			@round_qnt decimal (16,6)  = null,
			@product_code varchar(50) ,
			@coff decimal (20,6),
			@costPrice  decimal (20,6) = null,
			@mdmKey int,
			@product_group nvarchar(1000),
			@analitic_direction nvarchar(1000),
			@business_unitid varchar(10)

  			
	select f.value  ProductCode
	into #products
	  from string_split(@product_code_set, ',') f
	where nullif(f.value,'') is not null


	declare @result table (ProductCode varchar(256),
					   CondVar decimal(8,2),
					   CondConst decimal(8,2),
					   CondOpp decimal(8,2),
					   NS decimal(12,4),
					   Correction decimal(12,4),
					   IsSebStDetected bit,
					   RaskhodPrice decimal(12,4),
					   SebSt decimal(12,4),
					   RevenueNoNDS decimal(12,4),
					   GrossNoNDS decimal(12,4),
					   MarginNoNDS decimal(12,4),
					   SalesProfitNoNDS decimal(12,4),
					   OppNoNDS decimal (12,4),
					   R1 decimal(12,4),
					   R2 decimal(12,4),
					   R3 decimal(12,4),
					   R3opp decimal(12,4),
					   Limit decimal(12,4),
					   Max2 int,
					   Min2 int,
					   CondVarVal decimal(8,2),
					   CondConstVal decimal(8,2),
					   CondOppVal decimal(8,2),
					   Country NVARCHAR(512),
					   CostType NVARCHAR(150),
					   AdditionalDelayCost DECIMAL(16,2)
					   ) 

	select  @coff =  @sum_set/ (select sum(s.[SumSold])
								from #products f
									join [IEK_Extensions].dbo.SelfCostModel s  with (nolock) on f.ProductCode = s.КодНоменклатуры	
								where isnull(QuantitySold,0) >0)


	declare c cursor for (select top 1 p.ProductCode,
								 s.QuantitySold*@coff,
								 pr.price,
								 ppr.[Код MDM],
								 cast(ddp.[БЕ ID] as varchar(10)),
								 ddp.[Направление аналитики],
								 ddp.[Подгруппа]
						    from #products p
							join SelfCostModel s with (nolock) on s.КодНоменклатуры = p.ProductCode
							join [CRM_MSCRM].[dbo].[product] pr on pr.iek_product_code = p.ProductCode collate Cyrillic_General_CI_AI
							join [SERVER].[DB].[Обмены CRM].[Продукт.Продукт] ppr on ppr.[Код 1C] = p.ProductCode collate Cyrillic_General_CI_AI
																AND ppr.[Дата удаления из ассортимента] IS NULL 
																AND ppr.[Код 1C] is not NULL
							JOIN [SERVER].[DB].[Обмены CRM].[Продукт.ДДП] ddp on ddp.[ДДП ID] = ppr.[ДДП ID]
							where isnull(s.QuantitySold,0) >0 )
	open c 

	fetch next from c into @product_code, @round_qnt, @costPrice, @mdmKey, @business_unitid, @analitic_direction, @product_group
	while @@FETCH_STATUS =0 
	begin
		--select  @product_code, @round_qnt
		--print convert(varchar(100),getdate(), 21) +  '   ' +  @product_code + '   qnt = ' + convert(varchar(30),@round_qnt)
		insert into @result 
		exec IEK_Extensions.dbo.GetProductRenatbilityCalculation 
				@product_code  = @product_code,
				@rentabilityid = @rentabilityid,
				@qnt = @qnt,
				@round_qnt   = @round_qnt,
				@wanted_discount  = @wanted_discount,
				@payment_type  = @payment_type,
				@regionid = @regionid,
				@partner_status = @partner_status,
				@product_price = @costPrice,
				@product_group = @product_group,
				@check_avg_bonus = @check_avg_bonus,
				@business_unitid = @business_unitid,
				@analitic_direction = @analitic_direction
				

		fetch next from c into  @product_code, @round_qnt, @costPrice, @mdmKey, @business_unitid, @analitic_direction, @product_group
	end
	close c
	deallocate c

	select sum(CondVar) [Усл перем расх],
		   sum(CondConst) [Усл пост расх],
		   sum(CondOpp) [Вменен_расх],
		   sum(NS) [НС],
		   sum(Correction) [Корректировка_МП],
		   cast(max(cast (IsSebStDetected as tinyint)) as bit) [Себестоимость Определена],
		   sum(SebSt) [СебЕд_без НДС руб],
		   sum(RevenueNoNDS) [Выручка В ТЦ без НДС],
		   sum(GrossNoNDS) [Валовая Прибыль без НДС],
		   sum(MarginNoNDS) [Мар прибыль без НДС],
		   sum(SalesProfitNoNDS) [Прибыль от продаж без НДС],
		   sum(OppNoNDS) [Прибыль вменен без НДС],
		   sum(RaskhodPrice) [РасходнаяЦенаRUR],
		   sum(GrossNoNDS)/sum(RevenueNoNDS) [R1],
		   sum(MarginNoNDS)/sum(RevenueNoNDS) [R2],
		   sum(SalesProfitNoNDS)/sum(RevenueNoNDS) [R3],
		   sum(OppNoNDS)/sum(RevenueNoNDS) [R3opp]
	  from @result

		

end