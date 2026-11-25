USE [ECOMMERCE ANALYTICS DATABASE];


--------------------------------------------
-- ETL CONTROL, AUDIT & STAGING ARCHITECTURE
--------------------------------------------

DROP TABLE IF EXISTS ETL_DQ_Check_Results;
DROP TABLE IF EXISTS ETL_Batch_Audit_Log;
DROP TABLE IF EXISTS Target_Fact_Sales;
DROP TABLE IF EXISTS ETL_Staging_Sales;

-- 1. STAGING TABLE: Where raw daily batches land before validation
CREATE TABLE ETL_Staging_Sales (
    Staging_Row_ID INT IDENTITY(1,1) PRIMARY KEY,
    Batch_ID INT NOT NULL,
    InvoiceNo VARCHAR(20) NULL,
    Customer_ID INT NULL,
    Product_Code NVARCHAR(50) NULL,
    Quantity INT NULL,
    Unit_Price DECIMAL(10, 2) NULL,
    Order_Date DATETIME NULL
);

-- 2. TARGET PRODUCTION TABLE: Only 100% validated batches enter here!
CREATE TABLE Target_Fact_Sales (
    Fact_Sale_ID INT IDENTITY(1,1) PRIMARY KEY,
    Batch_ID INT NOT NULL,
    InvoiceNo VARCHAR(20) NOT NULL UNIQUE, -- Enforces NO duplicates in production!
    Customer_ID INT NOT NULL,
    Product_Code NVARCHAR(50) NOT NULL,
    Quantity INT NOT NULL,
    Unit_Price DECIMAL(10, 2) NOT NULL,
    Line_Revenue AS (CAST(Quantity * Unit_Price AS DECIMAL(12, 2))), -- Auto-calculated column!
    Order_Date DATETIME NOT NULL,
    Loaded_At DATETIME DEFAULT GETDATE()
);

-- 3. BATCH AUDIT LOG TABLE: Tracks high-level batch status & row reconciliation
CREATE TABLE ETL_Batch_Audit_Log (
    Batch_ID INT PRIMARY KEY,
    Batch_Name VARCHAR(100) NOT NULL,
    Start_Time DATETIME DEFAULT GETDATE(),
    End_Time DATETIME NULL,
    Expected_Source_Rows INT NOT NULL,
    Staging_Row_Count INT NULL,
    Target_Loaded_Rows INT NULL,
    Batch_Status VARCHAR(20) NOT NULL, -- 'RUNNING', 'SUCCESS', or 'FAILED'
    Error_Message NVARCHAR(500) NULL
);

-- 4. DATA QUALITY (DQ) RESULTS TABLE: Logs PASS / FAIL for each rule per batch
CREATE TABLE ETL_DQ_Check_Results (
    Check_ID INT IDENTITY(1,1) PRIMARY KEY,
    Batch_ID INT NOT NULL,
    Check_Name VARCHAR(100) NOT NULL,
    Failed_Row_Count INT NOT NULL,
    Check_Status VARCHAR(10) NOT NULL, -- 'PASS' or 'FAIL'
    Checked_At DATETIME DEFAULT GETDATE()
);

-- Quick verification that all 4 tables exist
SELECT name AS Created_ETL_Tables, create_date 
FROM sys.tables 
WHERE name IN ('ETL_Staging_Sales', 'Target_Fact_Sales', 'ETL_Batch_Audit_Log', 'ETL_DQ_Check_Results');


--------------------------------------------
-- SEED STAGING DATA (BATCH 101 & BATCH 102)
--------------------------------------------

-- Clear staging in case of previous test runs
TRUNCATE TABLE ETL_Staging_Sales;

-- 1. Grab 3 real customer IDs and 3 real product codes from the E-commerce master tables
DECLARE @Cust1 INT = (SELECT TOP 1 Customer_ID FROM Ecomm_Customers ORDER BY Customer_ID ASC);
DECLARE @Cust2 INT = (SELECT TOP 1 Customer_ID FROM Ecomm_Customers ORDER BY Customer_ID DESC);
DECLARE @Cust3 INT = (SELECT TOP 1 Customer_ID FROM Ecomm_Customers WHERE Customer_ID NOT IN (@Cust1, @Cust2));

DECLARE @Prod1 NVARCHAR(50) = (SELECT TOP 1 Product_Code FROM Ecomm_Products ORDER BY Product_Code ASC);
DECLARE @Prod2 NVARCHAR(50) = (SELECT TOP 1 Product_Code FROM Ecomm_Products ORDER BY Product_Code DESC);
DECLARE @Prod3 NVARCHAR(50) = (SELECT TOP 1 Product_Code FROM Ecomm_Products WHERE Product_Code NOT IN (@Prod1, @Prod2));

-- 2. INSERT BATCH 101: 100% Clean Data (5 Rows)
INSERT INTO ETL_Staging_Sales (Batch_ID, InvoiceNo, Customer_ID, Product_Code, Quantity, Unit_Price, Order_Date)
VALUES 
    (101, 'INV-1001', @Cust1, @Prod1, 2, 15.50, '2026-10-26 10:15:00'),
    (101, 'INV-1002', @Cust2, @Prod2, 1, 24.00, '2026-10-26 11:30:00'),
    (101, 'INV-1003', @Cust3, @Prod3, 5, 9.99,  '2026-10-26 13:45:00'),
    (101, 'INV-1004', @Cust1, @Prod2, 3, 24.00, '2026-10-26 15:20:00'),
    (101, 'INV-1005', @Cust2, @Prod1, 1, 15.50, '2026-10-26 16:10:00');

-- 3. INSERT BATCH 102: "Dirty Data" with Deliberate Defects (9 Rows)
INSERT INTO ETL_Staging_Sales (Batch_ID, InvoiceNo, Customer_ID, Product_Code, Quantity, Unit_Price, Order_Date)
VALUES 
    (102, 'INV-9901', @Cust1,  @Prod1,        4,   12.00, '2026-10-27 09:00:00'), -- Valid row
    (102, NULL,       @Cust2,  @Prod2,        1,   18.50, '2026-10-27 09:15:00'), -- DEFECT 1: NULL InvoiceNo
    (102, 'INV-9902', NULL,    @Prod3,        2,   10.00, '2026-10-27 09:30:00'), -- DEFECT 2: NULL Customer_ID
    (102, 'INV-9903', @Cust3,  @Prod1,        3,   15.50, '2026-10-27 10:00:00'), -- DEFECT 3: Duplicate Invoice (Row A)
    (102, 'INV-9903', @Cust1,  @Prod2,        1,   25.00, '2026-10-27 10:05:00'), -- DEFECT 3: Duplicate Invoice (Row B)
    (102, 'INV-9904', @Cust2,  @Prod3,       -2,   10.00, '2026-10-27 10:30:00'), -- DEFECT 4: Negative Quantity
    (102, 'INV-9905', @Cust3,  @Prod1,        1,    0.00, '2026-10-27 11:00:00'), -- DEFECT 5: Zero/Invalid Unit Price
    (102, 'INV-9906', 999999,  @Prod2,        2,   20.00, '2026-10-27 11:15:00'), -- DEFECT 6: Orphan Customer_ID (Does not exist)
    (102, 'INV-9907', @Cust1,  N'GHOST_ITEM', 1,   30.00, '2026-10-27 11:30:00'); -- DEFECT 7: Orphan Product_Code (Does not exist)

-- 4. Verify rows loaded per batch
SELECT Batch_ID, COUNT(*) AS Staging_Rows 
FROM ETL_Staging_Sales 
GROUP BY Batch_ID;


-------------------------------------------------
-- AUTOMATED DQ & RECONCILIATION STORED PROCEDURE
-------------------------------------------------

GO
CREATE OR ALTER PROCEDURE sp_Run_ETL_Batch_Pipeline
    @BatchID INT,
    @BatchName VARCHAR(100),
    @ExpectedSourceRows INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ActualStagingRows INT;
    DECLARE @TotalFailedChecks INT;

    -- Clean up any previous test logs for this Batch_ID so we can re-run cleanly
    DELETE FROM ETL_DQ_Check_Results WHERE Batch_ID = @BatchID;
    DELETE FROM ETL_Batch_Audit_Log WHERE Batch_ID = @BatchID;
    DELETE FROM Target_Fact_Sales WHERE Batch_ID = @BatchID;

    -- 1. Count actual rows sitting in Staging for this Batch
    SELECT @ActualStagingRows = COUNT(*) 
    FROM ETL_Staging_Sales 
    WHERE Batch_ID = @BatchID;

    -- 2. Initialize the Batch Audit Log as 'RUNNING'
    INSERT INTO ETL_Batch_Audit_Log (
        Batch_ID, Batch_Name, Start_Time, Expected_Source_Rows, Staging_Row_Count, Batch_Status
    )
    VALUES (
        @BatchID, @BatchName, GETDATE(), @ExpectedSourceRows, @ActualStagingRows, 'RUNNING'
    );

    ------------------------------------------------------
    -- EXECUTE THE 5 AUTOMATED DATA QUALITY (DQ) CHECKS
    ------------------------------------------------------

    -- CHECK 1: Source-to-Staging Row Count Reconciliation
    INSERT INTO ETL_DQ_Check_Results (Batch_ID, Check_Name, Failed_Row_Count, Check_Status)
    SELECT 
        @BatchID,
        '1. Row Count Reconciliation',
        ABS(@ExpectedSourceRows - @ActualStagingRows),
        CASE WHEN @ExpectedSourceRows = @ActualStagingRows THEN 'PASS' ELSE 'FAIL' END;

    -- CHECK 2: Critical NULL Value Check
    INSERT INTO ETL_DQ_Check_Results (Batch_ID, Check_Name, Failed_Row_Count, Check_Status)
    SELECT 
        @BatchID,
        '2. Mandatory Column NULL Check',
        COUNT(*),
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
    FROM ETL_Staging_Sales
    WHERE Batch_ID = @BatchID
      AND (InvoiceNo IS NULL OR Customer_ID IS NULL OR Product_Code IS NULL OR Quantity IS NULL OR Unit_Price IS NULL);

    -- CHECK 3: Duplicate InvoiceNo Check
    WITH Dup_CTE AS (
        SELECT InvoiceNo
        FROM ETL_Staging_Sales
        WHERE Batch_ID = @BatchID AND InvoiceNo IS NOT NULL
        GROUP BY InvoiceNo
        HAVING COUNT(*) > 1
    )
    INSERT INTO ETL_DQ_Check_Results (Batch_ID, Check_Name, Failed_Row_Count, Check_Status)
    SELECT 
        @BatchID,
        '3. Duplicate Invoice Check',
        COUNT(*),
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
    FROM Dup_CTE;

    -- CHECK 4: Invalid Quantity or Unit Price Check (<= 0)
    INSERT INTO ETL_DQ_Check_Results (Batch_ID, Check_Name, Failed_Row_Count, Check_Status)
    SELECT 
        @BatchID,
        '4. Positive Quantity & Price Check',
        COUNT(*),
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
    FROM ETL_Staging_Sales
    WHERE Batch_ID = @BatchID
      AND (Quantity <= 0 OR Unit_Price <= 0);

    -- CHECK 5: Referential Integrity (Orphan Customer_ID or Product_Code)
    INSERT INTO ETL_DQ_Check_Results (Batch_ID, Check_Name, Failed_Row_Count, Check_Status)
    SELECT 
        @BatchID,
        '5. Referential Integrity (Master Lookup) Check',
        COUNT(*),
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
    FROM ETL_Staging_Sales s
    LEFT JOIN Ecomm_Customers c ON s.Customer_ID = c.Customer_ID
    LEFT JOIN Ecomm_Products p ON s.Product_Code = p.Product_Code
    WHERE s.Batch_ID = @BatchID
      AND s.Customer_ID IS NOT NULL 
      AND s.Product_Code IS NOT NULL
      AND (c.Customer_ID IS NULL OR p.Product_Code IS NULL);


    ---------------------------------------------------------------
    -- EVALUATE DQ GATE & LOAD TARGET FACT TABLE (WITH TRY...CATCH)
    ---------------------------------------------------------------

    SELECT @TotalFailedChecks = COUNT(*)
    FROM ETL_DQ_Check_Results
    WHERE Batch_ID = @BatchID AND Check_Status = 'FAIL';

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Gatekeeper Rule: If ANY check failed, abort and throw custom error!
        IF @TotalFailedChecks > 0
        BEGIN
            THROW 50001, 'DQ Gate Failed: Batch contains critical data quality or reconciliation errors. Target load aborted.', 1;
        END

        -- If all checks PASS, load clean rows into Target_Fact_Sales
        INSERT INTO Target_Fact_Sales (Batch_ID, InvoiceNo, Customer_ID, Product_Code, Quantity, Unit_Price, Order_Date)
        SELECT Batch_ID, InvoiceNo, Customer_ID, Product_Code, Quantity, Unit_Price, Order_Date
        FROM ETL_Staging_Sales
        WHERE Batch_ID = @BatchID;

        -- Update Audit Log as SUCCESS
        UPDATE ETL_Batch_Audit_Log
        SET End_Time = GETDATE(),
            Target_Loaded_Rows = @@ROWCOUNT,
            Batch_Status = 'SUCCESS',
            Error_Message = 'All 5 DQ Checks Passed. Batch loaded to Target.'
        WHERE Batch_ID = @BatchID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- If anything failed, rollback the transaction so Target stays 100% clean!
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Log the exact failure in the Batch Audit Log
        UPDATE ETL_Batch_Audit_Log
        SET End_Time = GETDATE(),
            Target_Loaded_Rows = 0,
            Batch_Status = 'FAILED',
            Error_Message = ERROR_MESSAGE()
        WHERE Batch_ID = @BatchID;
    END CATCH
END;
GO

--------------------------------------------
-- EXECUTE & VALIDATE TEST BATCHES
--------------------------------------------

-- Run Batch 101 (Clean Batch -> Should PASS and load 5 rows)
EXEC sp_Run_ETL_Batch_Pipeline 
    @BatchID = 101, 
    @BatchName = 'Daily_Sales_20261026', 
    @ExpectedSourceRows = 5;

-- Run Batch 102 (Dirty Batch -> Should FAIL DQ Gate and load 0 rows)
EXEC sp_Run_ETL_Batch_Pipeline 
    @BatchID = 102, 
    @BatchName = 'Daily_Sales_20261027', 
    @ExpectedSourceRows = 10;

-- Review Audit Log & DQ Check Results
SELECT * FROM ETL_Batch_Audit_Log ORDER BY Batch_ID;
SELECT * FROM ETL_DQ_Check_Results ORDER BY Batch_ID, Check_ID;

-- Check production table contents
SELECT 
    Batch_ID, 
    COUNT(*) AS Target_Loaded_Rows,
    MIN(Order_Date) AS Earliest_Date,
    MAX(Order_Date) AS Latest_Date,
    SUM(Line_Revenue) AS Total_Batch_Revenue
FROM Target_Fact_Sales
GROUP BY Batch_ID;