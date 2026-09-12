using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;
using Microsoft.Xrm.Tooling.Connector;
using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Data;
using System.Linq;
using System.Runtime;
using System.Text;
using System.Threading.Tasks;
using System.Activities.Expressions;
using System.IO;
using System.Workflow.Runtime.Tracking;
using Newtonsoft.Json.Linq;
using System.Configuration;

namespace CalculatingFactProfitability
{
    internal class Program
    {
        static CrmServiceClient crmServiceClient;
        static StreamWriter logSession;
        static void Main(string[] args)
        {
            // Начало записи в лог
            var logDirPath = System.Configuration.ConfigurationManager.AppSettings["Log"];
            logSession = new StreamWriter(logDirPath + "\\SessionLog.txt", true) { AutoFlush = true };

            WriteLog("Начало сеанса расчета рентабельности. ", new List<StreamWriter> { logSession });

            try 
            {
                // Подключение к CRM
                crmServiceClient = new CrmServiceClient(System.Configuration.ConfigurationManager.ConnectionStrings["CRM"].ConnectionString);

                if (crmServiceClient.IsReady)
                {
                    WriteLog("Установлено соединение с CRM. ", new List<StreamWriter> { logSession });

                    // Получение данных записей Проектных скидок и Заявок Акций
                    var discounts = GetDicountApps();
                    var promos = GetPromoApps();

                    // Если был произведён полный скан по всем записям (т.е. приложение запущено в первый раз)
                    if (Convert.ToBoolean(System.Configuration.ConfigurationManager.AppSettings["FullScan"]))
                    {
                        // Переключаем параметр в конфиге
                        Configuration configuration = ConfigurationManager.OpenExeConfiguration(ConfigurationUserLevel.None);
                        configuration.AppSettings.Settings["FullScan"].Value = "False";
                        configuration.Save(ConfigurationSaveMode.Full, true);
                        ConfigurationManager.RefreshSection("appSettings");
                    }

                    // Форматирование данных записей по проектам
                    var data = GetFormatedCRMData(discounts, promos);

                    // Получаем данные об фактической себестоимости
                    RetrieveSelfCostFrom1C(data);

                    // Расчитываем рентабельность для записей
                    CalculateR1ForData(data);

                    // Заносим данные об рентабельности в CRM
                    UpdateDataInCRM(data);
                } 
                else
                {
                    WriteLog("Установить соединение с CRM не удалось. ", new List<StreamWriter> { logSession });
                }
            } 
            catch (Exception ex) 
            {
                // Сохраняем ошибку в логе
                WriteLog("Возникла ошибка при работе приложения. Ошибка: " + ex, new List<StreamWriter> { logSession });
            }

            // Оканчиваем запись в лог
            WriteLog("Окончание сеанса расчета рентабельности. ", new List<StreamWriter> { logSession });
            logSession.WriteLine("\n");
            logSession.Close();
        }

        // Функция записи данных в лог
        static void WriteLog(string message, List<StreamWriter> logFiles = default(List<StreamWriter>))
        {
            // Добавляем дату и время в лог
            message = message + "- " + DateTime.Now.ToString().Replace(':', '-');

            // выводим строку в лог и консоль
            Console.WriteLine($"{message}");
            foreach (StreamWriter logFile in logFiles)
            {
                logFile.WriteLine($"{message}");
            }
        }

        // Функция получения записей Проектных скидок
        private static DataCollection<Entity> GetDicountApps()
        {
            WriteLog($"Получение записей Проектных скидок. ", new List<StreamWriter> { logSession });

            // Формируем запрос на получение записей продуктов Проектных скидок с заполненой Отгруженной суммой и Результатом "Выйграна"
            QueryExpression query = new QueryExpression("crmpark_discount_app");
            query.ColumnSet = new ColumnSet("crmpark_discount_appid", "crmpark_projectid");
            query.Criteria.AddCondition("crmpark_resultcode", ConditionOperator.Equal, 557180000); // Результат = Выйграна
            var linkEntity = query.AddLink("crmpark_discount_app_product", "crmpark_discount_appid", "crmpark_discount_appid", JoinOperator.Inner);
            linkEntity.Columns.AddColumns("crmpark_discount_app_productid", "crmpark_shipped_amount", "crmpark_product_countryid");
            linkEntity.LinkCriteria.AddCondition("crmpark_shipped_amount", ConditionOperator.NotNull);
            // Если для приложения не требуется полный скан по всем записям (т.е. оно запущено не в первый раз)
            if (!Convert.ToBoolean(System.Configuration.ConfigurationManager.AppSettings["FullScan"]))
            {
                // Добавляем условие на период за последние два месяца 
                linkEntity.LinkCriteria.AddCondition("crmpark_shipped_date", ConditionOperator.OnOrAfter, new DateTime(DateTime.Now.Year, DateTime.Now.Month, 1).AddMonths(-1));
                linkEntity.LinkCriteria.AddCondition("crmpark_shipped_date", ConditionOperator.OnOrBefore, new DateTime(DateTime.Now.Year, DateTime.Now.Month, 1).AddMonths(1).AddSeconds(-1));
            }
            var linkEntityProduct = linkEntity.AddLink("crmpark_product_country", "crmpark_product_countryid", "crmpark_product_countryid", JoinOperator.Inner);
            linkEntityProduct.Columns.AddColumns("crmpark_productid");
            
            // Получаем результат запроса и сохраняем информацию о нём в логе
            var result = crmServiceClient.RetrieveMultiple(query).Entities;
            WriteLog($"Получены записи Проектных скидок. Количество: {result.Count}. ", new List<StreamWriter> { logSession });

            return result;
        }

        // Функция получения записей Заявок акций
        private static DataCollection<Entity> GetPromoApps()
        {
            WriteLog($"Получение записей Заявок акций. ", new List<StreamWriter> { logSession });

            // Формируем запрос на получение записей продуктов Заявок акций с заполненой Отгруженной суммой и Результатом "Выйграна"
            QueryExpression query = new QueryExpression("crmpark_promo_app");
            query.ColumnSet = new ColumnSet("crmpark_promo_appid");
            query.Criteria.AddCondition("crmpark_resultcode", ConditionOperator.Equal, 557180000); // Результат = Выйграна
            var linkEntity = query.AddLink("crmpark_promo_app_product", "crmpark_promo_appid", "crmpark_promo_appid", JoinOperator.Inner);
            linkEntity.Columns.AddColumns("crmpark_promo_app_productid", "crmpark_shipped_amount", "crmpark_product_countryid");
            linkEntity.LinkCriteria.AddCondition("crmpark_shipped_amount", ConditionOperator.NotNull);
            // Если для приложения не требуется полный скан по всем записям (т.е. оно запущено не в первый раз)
            if (!Convert.ToBoolean(System.Configuration.ConfigurationManager.AppSettings["FullScan"]))
            {
                // Добавляем условие на период за последние два месяца 
                linkEntity.LinkCriteria.AddCondition("crmpark_shipped_date", ConditionOperator.OnOrAfter, new DateTime(DateTime.Now.Year, DateTime.Now.Month, 1).AddMonths(-1));
                linkEntity.LinkCriteria.AddCondition("crmpark_shipped_date", ConditionOperator.OnOrBefore, new DateTime(DateTime.Now.Year, DateTime.Now.Month, 1).AddMonths(1).AddSeconds(-1));
            }
            var linkEntityProduct = linkEntity.AddLink("crmpark_product_country", "crmpark_product_countryid", "crmpark_product_countryid", JoinOperator.Inner);
            linkEntityProduct.Columns.AddColumns("crmpark_product_countryid", "crmpark_productid");

            // Получаем результат запроса и сохраняем информацию о нём в логе
            var result = crmServiceClient.RetrieveMultiple(query).Entities;
            WriteLog($"Получены записи Заявок акций. Количество: {result.Count}. ", new List<StreamWriter> { logSession });

            return result;
        }

        private static Data GetFormatedCRMData(DataCollection<Entity> discounts, DataCollection<Entity> promos)
        {
            WriteLog($"Форматирование полученных данных. ", new List<StreamWriter> { logSession });

            var data = new Data()
            {
                Discounts = new List<Project>(),
                Promos = new List<Record>()
            };

            // Форматируем записи Проектных скидок в удобный формат
            foreach (var discount in discounts)
            {
                // Добавляем данные проекта в общий массив данных
                var projectId = discount.GetAttributeValue<EntityReference>("crmpark_projectid").Id;
                if (!data.Discounts.Any(x => x.Id == projectId))
                {
                    data.Discounts.Add(new Project() { Id = projectId, Records = new List<Record>() });
                }
                var project = data.Discounts.Find(x => x.Id == projectId);

                // Добавляем данные скидки в запись проекта
                var discountAppId = discount.GetAttributeValue<Guid>("crmpark_discount_appid");
                if (!project.Records.Any(x => x.Id == discountAppId))
                {
                    project.Records.Add(new Record() { Id = discountAppId, Products = new List<Product>() });
                }
                var discountApp = project.Records.Find(x => x.Id == discountAppId);

                // Добавляем данные продукта в запись скидки (GUID записи, GUID продукта и сумма)
                discountApp.Products.Add(new Product()
                {
                    Id = (Guid)discount.GetAttributeValue<AliasedValue>("crmpark_discount_app_product1.crmpark_discount_app_productid").Value,
                    ProductId = ((EntityReference)discount.GetAttributeValue<AliasedValue>("crmpark_product_country2.crmpark_productid").Value).Id,
                    Cost = ((Money)discount.GetAttributeValue<AliasedValue>("crmpark_discount_app_product1.crmpark_shipped_amount").Value).Value
                });
            }

            // Форматируем записи Заявок акций в удобный формат
            foreach (var promo in promos)
            {
                // Добавляем данные заявки в общий массив данных
                var promoAppId = promo.GetAttributeValue<Guid>("crmpark_promo_appid");
                if (!data.Promos.Any(x => x.Id == promoAppId))
                {
                    data.Promos.Add(new Record() { Id = promoAppId, Products = new List<Product>() });
                }
                var promoApp = data.Promos.Find(x => x.Id == promoAppId);

                // Добавляем данные продукта в запись заявки (GUID записи, GUID продукта и сумма)
                promoApp.Products.Add(new Product()
                {
                    Id = (Guid)promo.GetAttributeValue<AliasedValue>("crmpark_promo_app_product1.crmpark_promo_app_productid").Value,
                    ProductId = ((EntityReference)promo.GetAttributeValue<AliasedValue>("crmpark_product_country2.crmpark_productid").Value).Id,
                    Cost = ((Money)promo.GetAttributeValue<AliasedValue>("crmpark_promo_app_product1.crmpark_shipped_amount").Value).Value
                });
            }

            WriteLog($"Форматирование завершено. ", new List<StreamWriter> { logSession });
            return data;
        }

        private static void RetrieveSelfCostFrom1C(Data data)
        {
            List<String> productIds = new List<String>();

            WriteLog($"Получение фактических себестоимостей из 1С. ", new List<StreamWriter> { logSession });

            // Для всех проектов в общем массиве данных
            foreach (var project in data.Discounts)
            {
                // Для всех скидок в проекте
                foreach (var discountApp in project.Records)
                {
                    // Добавляем GUID всех продуктов в строку со списком Id продуктов и периодов (в формате <Id period>) через запятую для вставки в SQL-запрос
                    productIds.AddRange(discountApp.Products.Select(p => $"'{p.ProductId}'").ToList());
                }
            }

            // Для всех заявок в общем массиве данных
            foreach (var promo in data.Promos)
            {
                // Добавляем GUID всех продуктов в строку со списком Id продуктов и периодов (в формате <Id period>) через запятую для вставки в SQL-запрос
                productIds.AddRange(promo.Products.Select(p => $"'{p.ProductId}'").ToArray());
            }

            var unfoundIds = productIds;

            // Подключаемся в SQL
            using (var con = new SqlConnection(System.Configuration.ConfigurationManager.ConnectionStrings["SQL"].ConnectionString))
            {
                con.Open();

                var sql = $"SELECT [ProductId], [SelfCost] FROM [IEK_Extensions].[dbo].[FactSelfCostModel] WHERE [ProductId] IN ({string.Join(",", productIds)}) AND Period = '{DateTime.Now.Year.ToString()}-{DateTime.Now.Month.ToString("D2")}'";

                // Посылаем запрос на получение данных по себестоимости продукции 
                SqlCommand command = new SqlCommand(sql, con);
                command.CommandType = CommandType.Text;
                using (SqlDataReader reader = command.ExecuteReader())
                {
                    // Считываем результат построчно
                    while (reader.Read())
                    {
                        // Получаем себебстоимость и GUID соответствующего продукта
                        var productId = (Guid)reader["ProductId"];
                        var selfCost = (decimal)reader["SelfCost"];

                        // Ищем продукт в записях Скидок
                        var dicountProduct = data.Discounts.SelectMany(p => p.Records).SelectMany(d => d.Products).FirstOrDefault(p => p.Id == productId);
                        if (dicountProduct != null)
                        {
                            // При нахождении сохраняем результат
                            dicountProduct.SelfCost = selfCost;
                        }

                        // Ищем продукт в записях Заявок
                        var promoProduct = data.Promos.SelectMany(d => d.Products).FirstOrDefault(p => p.Id == productId);
                        if (promoProduct != null)
                        {
                            // При нахождении сохраняем результат
                            promoProduct.SelfCost = selfCost;
                        }

                        unfoundIds.Remove(productId.ToString());
                    }
                }
            }

            // Проверяем, для скольких продуктов была найдена себестоимость 
            var fullCount = productIds.Count();
            var foundCount = productIds.Count() - unfoundIds.Count();
            WriteLog($"Себестоимости получены. Кол-во успешно полученных себестоимостей: {foundCount} из {fullCount}. ", new List<StreamWriter> { logSession });
            if (fullCount != foundCount)
            {
                // Выводим GUID ненайденных продуктов
                WriteLog($"Ненайденные продукты: {string.Join(",", unfoundIds)}. ", new List<StreamWriter> { logSession });
            }
        }

        private static void CalculateR1ForData(Data data)
        {
            WriteLog($"Запуск процесса расчета рентабельности для записей. ", new List<StreamWriter> { logSession });

            // Для каждого проекта в общем массиве данных
            foreach (var project in data.Discounts)
            {
                decimal currentProjectR1Sum = 0;
                int currentProjectR1Count = 0;

                // Для каждой скидки в проекте
                foreach (var record in project.Records)
                {
                    decimal currentDiscountR1Sum = 0;
                    int currentDiscountR1Count = 0;

                    // Для каждого продукта в скидке
                    foreach (var product in record.Products)
                    {
                        // Вычисляем и сохраняем рентабельность продуктов по их сумме и себебстоимости
                        decimal productR1 = (product.Cost - product.SelfCost) / product.Cost;
                        product.Fact_R1 = productR1;
                        currentDiscountR1Sum += productR1;
                        ++currentDiscountR1Count;
                    }

                    // Вычисляем и сохраняем рентабельность скидки как среднюю рентабельность её продуктов
                    decimal discountR1 = currentDiscountR1Sum / currentDiscountR1Count;
                    record.Fact_R1 = discountR1;
                    currentProjectR1Sum += discountR1;
                    ++currentProjectR1Count;
                }

                // Вычисляем и сохраняем рентабельность проекта как среднюю рентабельность её скидок
                project.Fact_R1 = currentProjectR1Sum / currentProjectR1Count;
            }

            // Для каждой заявки в общем массиве данных
            foreach (var record in data.Promos)
            {
                decimal currentDiscountR1Sum = 0;
                int currentDiscountR1Count = 0;

                // Для каждого продукта в заявке
                foreach (var product in record.Products)
                {
                    // Вычисляем и сохраняем рентабельность продуктов по их сумме и себебстоимости
                    decimal productR1 = (product.Cost - product.SelfCost) / product.Cost;
                    product.Fact_R1 = productR1;
                    currentDiscountR1Sum += productR1;
                    ++currentDiscountR1Count;
                }

                // Вычисляем и сохраняем рентабельность заявки как среднюю рентабельность её продуктов
                record.Fact_R1 = currentDiscountR1Sum / currentDiscountR1Count;
            }

            WriteLog($"Расчет рентабельности завершён. ", new List<StreamWriter> { logSession });
        }

        private static void UpdateDataInCRM(Data data)
        {
            WriteLog($"Отправка данных в CRM. ", new List<StreamWriter> { logSession });

            // Для каждого проекта в общем массиве данных
            foreach (var project in data.Discounts)
            {
                // Для каждой скидки в проекте
                foreach (var record in project.Records)
                {
                    // Для каждого продукта в скидке
                    foreach (var product in record.Products)
                    {
                        // Формирует и отправляет запрос на обновление записи Продукта скидки для записи расчитанной рентабельности
                        var productUpdate = new Entity("crmpark_discount_app_product", product.Id)
                        {
                            ["crmpark_fact_r1"] = product.Fact_R1
                        };
                        crmServiceClient.Update(productUpdate);
                    }

                    // Формирует и отправляет запрос на обновление записи Проектной скидки для записи расчитанной рентабельности
                    var discountUpdate = new Entity("crmpark_discount_app", record.Id)
                    {
                        ["crmpark_fact_r1"] = record.Fact_R1
                    };
                    crmServiceClient.Update(discountUpdate);
                }

                // Формирует и отправляет запрос на обновление записи Проекта для записи расчитанной рентабельности
                var projectUpdate = new Entity("crmpark_project", project.Id)
                {
                    ["crmpark_fact_r1"] = project.Fact_R1
                };
                crmServiceClient.Update(projectUpdate);
            }

            foreach (var record in data.Promos)
            {
                foreach (var product in record.Products)
                {
                    // Формирует и отправляет запрос на обновление записи Продукта заявки для записи расчитанной рентабельности
                    var productUpdate = new Entity("crmpark_promo_app_product", product.Id)
                    {
                        ["crmpark_fact_r1"] = product.Fact_R1
                    };
                    crmServiceClient.Update(productUpdate);
                }

                // Формирует и отправляет запрос на обновление записи Заявки акций для записи расчитанной рентабельности
                var promoUpdate = new Entity("crmpark_promo_app", record.Id)
                {
                    ["crmpark_fact_r1"] = record.Fact_R1
                };
                crmServiceClient.Update(promoUpdate);
            }

            WriteLog($"Данные отправлены успешно. ", new List<StreamWriter> { logSession });
        }
    }

    // Класс для основных данных записи
    internal class Main
    {
        public Guid Id { get; set; }
        public decimal Fact_R1 { get; set; }
    }

    // Класс для данных Продукта
    internal class Product : Main
    {
        public Guid ProductId { get; set; }
        public decimal Cost { get; set; }
        public decimal SelfCost { get; set; }

    }

    // Класс для данных записи Проектой скидки или Заявки акций
    internal class Record : Main
    {
        public List<Product> Products { get; set; }
    }

    // Класс для данных Проекта
    internal class Project : Main
    {
        public List<Record> Records { get; set; }
    }

    // Класс для общих данных
    internal class Data
    {
        public List<Project> Discounts { get; set; }
        public List<Record> Promos { get; set; }
    }
}
