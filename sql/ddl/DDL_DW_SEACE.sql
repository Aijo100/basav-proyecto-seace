/* ============================================================================
   DDL_DW_SEACE.sql   (evidencia E-06 - borrador de diseño para la T2)
   Data warehouse de procesos de selección del SEACE (datos OCDS del OSCE).
   ESTADO: diseño NO ejecutado todavía. Validar contra SQL Server en la Semana 11.
   Los nombres de columnas de staging deben ajustarse al diccionario real de la
   descarga del portal, tras el perfilado (E-01).
   ============================================================================ */
IF DB_ID('DW_SEACE') IS NULL CREATE DATABASE DW_SEACE;
GO
USE DW_SEACE;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

/* ---------------------------- STAGING ---------------------------- */
CREATE TABLE stg.ocds_item (
    ocid                      VARCHAR(60)   NOT NULL,
    item_id                   VARCHAR(30)   NOT NULL,
    release_date              DATETIME2     NULL,
    buyer_id                  VARCHAR(20)   NULL,
    buyer_name                VARCHAR(250)  NULL,
    procurement_method        VARCHAR(60)   NULL,
    procurement_method_details VARCHAR(150) NULL,
    main_category             VARCHAR(20)   NULL,   -- goods / services / works
    tender_status             VARCHAR(30)   NULL,   -- p. ej. unsuccessful = desierto (confirmar)
    tender_start_date         DATE          NULL,
    award_date                DATE          NULL,
    tender_value_amount       DECIMAL(18,2) NULL,
    award_value_amount        DECIMAL(18,2) NULL,
    currency                  CHAR(3)       NULL,
    number_of_tenderers       INT           NULL,
    supplier_id               VARCHAR(20)   NULL,
    supplier_name             VARCHAR(250)  NULL,
    ubigeo                    CHAR(6)       NULL,
    source_file               VARCHAR(200)  NULL,
    loaded_at                 DATETIME2     NOT NULL DEFAULT SYSDATETIME()
);
CREATE TABLE stg.ubigeo (
    ubigeo       CHAR(6)      NOT NULL PRIMARY KEY,
    departamento VARCHAR(60)  NOT NULL,
    provincia    VARCHAR(60)  NOT NULL,
    distrito     VARCHAR(60)  NOT NULL
);

/* ------------------------ CONTROL DEL ETL ------------------------ */
CREATE TABLE etl.etl_log (
    log_id          BIGINT IDENTITY(1,1) PRIMARY KEY,
    procedimiento   VARCHAR(100)  NOT NULL,
    inicio          DATETIME2     NOT NULL,
    fin             DATETIME2     NULL,
    filas_leidas    INT           NULL,
    filas_cargadas  INT           NULL,
    estado          VARCHAR(10)   NOT NULL,        -- OK / ERROR
    mensaje         NVARCHAR(4000) NULL
);
CREATE TABLE etl.cuarentena (
    id      BIGINT IDENTITY(1,1) PRIMARY KEY,
    ocid    VARCHAR(60)  NULL,
    item_id VARCHAR(30)  NULL,
    motivo  VARCHAR(200) NOT NULL,
    fecha   DATETIME2    NOT NULL DEFAULT SYSDATETIME()
);
CREATE TABLE etl.aud_cambios (
    aud_id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    tabla          VARCHAR(60)   NOT NULL,
    clave          INT           NOT NULL,
    campo          VARCHAR(60)   NOT NULL,
    valor_anterior NVARCHAR(250) NULL,
    valor_nuevo    NVARCHAR(250) NULL,
    usuario        SYSNAME       NOT NULL,
    fecha          DATETIME2     NOT NULL
);

/* --------------------------- DIMENSIONES -------------------------- */
CREATE TABLE dw.Dim_Fecha (
    fecha_key   INT         NOT NULL PRIMARY KEY,   -- AAAAMMDD
    fecha       DATE        NOT NULL,
    dia         TINYINT     NOT NULL,
    mes         TINYINT     NOT NULL,
    nombre_mes  VARCHAR(15) NOT NULL,
    trimestre   TINYINT     NOT NULL,
    anio        SMALLINT    NOT NULL,
    dia_semana  VARCHAR(12) NOT NULL
);
CREATE TABLE dw.Dim_Entidad (                       -- SCD tipo 2
    entidad_key     INT IDENTITY(1,1) PRIMARY KEY,
    entidad_codigo  VARCHAR(20)  NOT NULL,
    entidad_nombre  VARCHAR(250) NOT NULL,
    nivel_gobierno  VARCHAR(40)  NULL,
    vigente_desde   DATE         NOT NULL,
    vigente_hasta   DATE         NULL,
    es_actual       BIT          NOT NULL DEFAULT 1
);
CREATE TABLE dw.Dim_Proveedor (                     -- SCD tipo 1
    proveedor_key     INT IDENTITY(1,1) PRIMARY KEY,
    proveedor_id_hash CHAR(64)     NOT NULL UNIQUE, -- SHA-256 (anonimizado)
    proveedor_nombre  VARCHAR(250) NULL,            -- solo personas jurídicas
    tipo_proveedor    VARCHAR(20)  NOT NULL         -- JURIDICA / NATURAL
);
CREATE TABLE dw.Dim_Objeto (
    objeto_key INT IDENTITY(1,1) PRIMARY KEY,
    objeto     VARCHAR(20) NOT NULL UNIQUE          -- Bien / Servicio / Obra / Consultoría
);
CREATE TABLE dw.Dim_Procedimiento (
    procedimiento_key INT IDENTITY(1,1) PRIMARY KEY,
    codigo            VARCHAR(30)  NOT NULL UNIQUE,
    nombre            VARCHAR(150) NOT NULL
);
CREATE TABLE dw.Dim_Ubigeo (
    ubigeo_key   INT IDENTITY(1,1) PRIMARY KEY,
    ubigeo       CHAR(6)     NOT NULL UNIQUE,
    departamento VARCHAR(60) NOT NULL,
    provincia    VARCHAR(60) NOT NULL,
    distrito     VARCHAR(60) NOT NULL
);

/* ------------------------------ HECHOS ---------------------------- */
-- Grano: un registro por ítem de un proceso de selección convocado (ocid + ítem)
CREATE TABLE dw.Fact_Proceso (
    proceso_item_key        BIGINT IDENTITY(1,1) PRIMARY KEY,
    ocid_item               VARCHAR(80)   NOT NULL UNIQUE,
    fecha_convocatoria_key  INT           NOT NULL REFERENCES dw.Dim_Fecha(fecha_key),
    fecha_buenapro_key      INT           NULL     REFERENCES dw.Dim_Fecha(fecha_key),
    entidad_key             INT           NOT NULL REFERENCES dw.Dim_Entidad(entidad_key),
    proveedor_key           INT           NULL     REFERENCES dw.Dim_Proveedor(proveedor_key),
    objeto_key              INT           NOT NULL REFERENCES dw.Dim_Objeto(objeto_key),
    procedimiento_key       INT           NOT NULL REFERENCES dw.Dim_Procedimiento(procedimiento_key),
    ubigeo_key              INT           NULL     REFERENCES dw.Dim_Ubigeo(ubigeo_key),
    valor_referencial       DECIMAL(18,2) NULL,
    monto_adjudicado        DECIMAL(18,2) NULL,
    num_postores            INT           NULL,
    dias_conv_buenapro      INT           NULL,
    flag_desierto           BIT           NOT NULL,
    flag_adjudicado         BIT           NOT NULL
);
CREATE INDEX ix_fact_fecha_conv ON dw.Fact_Proceso(fecha_convocatoria_key);
CREATE INDEX ix_fact_entidad    ON dw.Fact_Proceso(entidad_key);
CREATE INDEX ix_fact_objeto     ON dw.Fact_Proceso(objeto_key, procedimiento_key);
GO

/* ------------------- TRIGGER DE AUDITORÍA (Dim_Entidad) ----------- */
CREATE TRIGGER dw.trg_aud_dim_entidad ON dw.Dim_Entidad
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.aud_cambios (tabla, clave, campo, valor_anterior, valor_nuevo, usuario, fecha)
    SELECT 'Dim_Entidad', i.entidad_key, 'entidad_nombre',
           d.entidad_nombre, i.entidad_nombre, SUSER_SNAME(), SYSDATETIME()
    FROM inserted i
    JOIN deleted  d ON d.entidad_key = i.entidad_key
    WHERE ISNULL(d.entidad_nombre, '') <> ISNULL(i.entidad_nombre, '');
END;
GO

/* ---------- EJEMPLO DE PROCEDIMIENTO ETL (SCD2 + TRY...CATCH) ------ */
CREATE PROCEDURE etl.usp_load_dim_entidad
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inicio DATETIME2 = SYSDATETIME(), @leidas INT = 0, @cargadas INT = 0;
    BEGIN TRY
        BEGIN TRAN;

        SELECT @leidas = COUNT(DISTINCT buyer_id)
        FROM stg.ocds_item WHERE buyer_id IS NOT NULL;

        -- 1) Cerrar la versión vigente si cambió el nombre (SCD tipo 2)
        UPDATE e
           SET e.vigente_hasta = CAST(SYSDATETIME() AS DATE), e.es_actual = 0
        FROM dw.Dim_Entidad e
        JOIN (SELECT buyer_id, MAX(UPPER(LTRIM(RTRIM(buyer_name)))) AS nombre
              FROM stg.ocds_item WHERE buyer_id IS NOT NULL GROUP BY buyer_id) s
          ON s.buyer_id = e.entidad_codigo
        WHERE e.es_actual = 1 AND e.entidad_nombre <> s.nombre;

        -- 2) Insertar entidades nuevas o nuevas versiones
        INSERT INTO dw.Dim_Entidad (entidad_codigo, entidad_nombre, vigente_desde)
        SELECT s.buyer_id, s.nombre, CAST(SYSDATETIME() AS DATE)
        FROM (SELECT buyer_id, MAX(UPPER(LTRIM(RTRIM(buyer_name)))) AS nombre
              FROM stg.ocds_item WHERE buyer_id IS NOT NULL GROUP BY buyer_id) s
        WHERE NOT EXISTS (SELECT 1 FROM dw.Dim_Entidad e
                          WHERE e.entidad_codigo = s.buyer_id AND e.es_actual = 1);
        SET @cargadas = @@ROWCOUNT;

        COMMIT;
        INSERT INTO etl.etl_log (procedimiento, inicio, fin, filas_leidas, filas_cargadas, estado)
        VALUES ('usp_load_dim_entidad', @inicio, SYSDATETIME(), @leidas, @cargadas, 'OK');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO etl.etl_log (procedimiento, inicio, fin, filas_leidas, filas_cargadas, estado, mensaje)
        VALUES ('usp_load_dim_entidad', @inicio, SYSDATETIME(), @leidas, 0, 'ERROR', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

/* ---------------- PROGRAMACIÓN (SQL Server Agent) - PLAN ----------
   Crear el job JOB_ETL_SEACE con pasos: staging, dimensiones, hechos y
   reconciliación (EXEC etl.usp_etl_master), 1 reintento y ejecución mensual.
   Usar msdb.dbo.sp_add_job, sp_add_jobstep, sp_add_jobschedule y sp_add_jobserver.
   Pendiente: usp_load_dim_* restantes, usp_load_fact_proceso y usp_etl_master.
   --
