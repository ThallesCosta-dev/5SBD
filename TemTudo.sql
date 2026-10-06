-- =========================================================================
-- SISTEMA DE PROCESSAMENTO DE PEDIDOS MARKETPLACE - BAZAR TEMTUDO
-- =========================================================================
GO

-- =========================================================================
-- 1. TABELAS DE CARGA E SISTEMA
-- =========================================================================

-- 1.1. Tabela Temporária de Carga de Pedidos (Staging Area)
-- Recebe exatamente a estrutura do arquivo CSV vindo do FTP dos Marketplaces
CREATE TABLE Carga (
    id_carga INT IDENTITY(1,1) PRIMARY KEY,
    order_id VARCHAR(100),
    order_item_id VARCHAR(100),
    purchase_date DATETIME,
    payments_date DATETIME,
    buyer_email VARCHAR(255),
    buyer_name VARCHAR(255),
    cpf VARCHAR(30), -- Recebe CPF, CNPJ ou Passaporte/Tax ID estrangeiro
    buyer_phone_number VARCHAR(50),
    sku VARCHAR(100),
    product_name VARCHAR(255),
    quantity_purchased INT,
    currency VARCHAR(10),
    item_price DECIMAL(10, 2),
    ship_service_level VARCHAR(50),
    recipient_name VARCHAR(255),
    ship_address_1 VARCHAR(255),
    ship_address_2 VARCHAR(255),
    ship_address_3 VARCHAR(255),
    ship_city VARCHAR(100),
    ship_state VARCHAR(100),
    ship_postal_code VARCHAR(50),
    ship_country VARCHAR(50),
    ioss_number VARCHAR(50)
);

-- 1.2. Tabela de Clientes
CREATE TABLE Clientes (
    cliente_id INT IDENTITY(1,1) PRIMARY KEY,
    documento_identificacao VARCHAR(30) NOT NULL UNIQUE, -- CPF (11d), CNPJ (14d) ou Doc. Estrangeiro
    tipo_documento VARCHAR(25) NOT NULL, -- 'CPF', 'CNPJ', 'ESTRANGEIRO_PASSAPORTE'
    nome VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    telefone VARCHAR(50),
    data_cadastro DATETIME DEFAULT GETDATE()
);

-- 1.3. Tabela de Produtos
CREATE TABLE Produtos (
    produto_id INT IDENTITY(1,1) PRIMARY KEY,
    sku VARCHAR(100) NOT NULL UNIQUE,
    nome_produto VARCHAR(255) NOT NULL,
    estoque_atual INT NOT NULL DEFAULT 0 CHECK (estoque_atual >= 0),
    data_cadastro DATETIME DEFAULT GETDATE()
);

-- 1.4. Tabela de Pedidos
CREATE TABLE Pedidos (
    pedido_id INT IDENTITY(1,1) PRIMARY KEY,
    order_id_marketplace VARCHAR(100) NOT NULL UNIQUE, -- ID de origem do marketplace
    cliente_id INT NOT NULL, -- PK de Clientes
    data_compra DATETIME,
    data_pagamento DATETIME,
    nivel_servico_envio VARCHAR(50),
    nome_destinatario VARCHAR(255),
    endereco_envio_1 VARCHAR(255),
    endereco_envio_2 VARCHAR(255),
    endereco_envio_3 VARCHAR(255),
    cidade_envio VARCHAR(100),
    estado_envio VARCHAR(100),
    cep_envio VARCHAR(50),
    pais_envio VARCHAR(50),
    numero_ioss VARCHAR(50),
    valor_total DECIMAL(10, 2) DEFAULT 0.00,
    status_pedido VARCHAR(30) DEFAULT 'Pendente', -- 'Pendente', 'Atendido', 'Aguardando Compra'
    data_registro DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_Pedidos_Clientes FOREIGN KEY (cliente_id) REFERENCES Clientes(cliente_id)
);

-- 1.5. Tabela de Itens do Pedido
CREATE TABLE ItensPedido (
    item_pedido_id INT IDENTITY(1,1) PRIMARY KEY,
    order_item_id_marketplace VARCHAR(100) NOT NULL UNIQUE,
    pedido_id INT NOT NULL, -- PK de Pedidos
    produto_id INT NOT NULL, -- PK de Produtos
    quantidade INT NOT NULL CHECK (quantidade > 0),
    moeda VARCHAR(10) DEFAULT 'BRL',
    preco_unitario DECIMAL(10, 2) NOT NULL,
    subtotal DECIMAL(10, 2) NOT NULL,
    CONSTRAINT FK_Itens_Pedidos FOREIGN KEY (pedido_id) REFERENCES Pedidos(pedido_id),
    CONSTRAINT FK_Itens_Produtos FOREIGN KEY (produto_id) REFERENCES Produtos(produto_id)
);

-- 1.6. Tabela de Movimentação de Estoque
CREATE TABLE MovimentacaoEstoque (
    movimentacao_id INT IDENTITY(1,1) PRIMARY KEY,
    pedido_id INT NULL, -- PK de Pedidos (NULL em caso de entradas de fornecedor)
    produto_id INT NOT NULL, -- PK de Produtos
    quantidade INT NOT NULL,
    tipo_movimentacao VARCHAR(10) NOT NULL, -- 'SAIDA' ou 'ENTRADA'
    saldo_anterior INT NOT NULL,
    saldo_posterior INT NOT NULL,
    data_movimentacao DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_Mov_Pedidos FOREIGN KEY (pedido_id) REFERENCES Pedidos(pedido_id),
    CONSTRAINT FK_Mov_Produtos FOREIGN KEY (produto_id) REFERENCES Produtos(produto_id)
);

-- 1.7. Tabela de Compras (Necessidade de Reposição)
CREATE TABLE Compras (
    compra_id INT IDENTITY(1,1) PRIMARY KEY,
    pedido_id INT NOT NULL, -- PK de Pedidos
    produto_id INT NOT NULL, -- PK de Produtos
    quantidade_necessaria INT NOT NULL CHECK (quantidade_necessaria > 0),
    status_compra VARCHAR(20) DEFAULT 'Pendente', -- 'Pendente' ou 'Recebido'
    data_registro DATETIME DEFAULT GETDATE(),
    CONSTRAINT FK_Comp_Pedidos FOREIGN KEY (pedido_id) REFERENCES Pedidos(pedido_id),
    CONSTRAINT FK_Comp_Produtos FOREIGN KEY (produto_id) REFERENCES Produtos(produto_id)
);

-- 1.8. Tabela de Carga de Compras (Recebimento de Fornecedores via CSV)
CREATE TABLE CargaCompras (
    id_carga_compra INT IDENTITY(1,1) PRIMARY KEY,
    sku VARCHAR(100) NOT NULL,
    quantidade_entregue INT NOT NULL CHECK (quantidade_entregue > 0)
);

GO

-- =========================================================================
-- 2. PROCEDURES DE PROCESSAMENTO (ETL E REGRAS DE NEGÓCIO)
-- =========================================================================

-- -------------------------------------------------------------------------
-- PROCEDURE: sp_ProcessarCarga
-- Objetivo: Migrar os dados da staging area (Carga) para as tabelas de 
--           Clientes, Produtos, Pedidos e ItensPedido usando LEFT JOIN 
--           (para evitar duplicatas) e INNER JOIN (para associar os IDs/PKs).
-- -------------------------------------------------------------------------
CREATE PROCEDURE sp_ProcessarCarga
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Inserção de Clientes Novos (Uso de LEFT JOIN para anti-join/deduplicação)
        INSERT INTO Clientes (documento_identificacao, tipo_documento, nome, email, telefone)
        SELECT DISTINCT
            LTRIM(RTRIM(c.cpf)) AS documento_identificacao,
            CASE 
                WHEN LEN(REPLACE(REPLACE(REPLACE(c.cpf, '.', ''), '-', ''), '/', '')) = 11 THEN 'CPF'
                WHEN LEN(REPLACE(REPLACE(REPLACE(c.cpf, '.', ''), '-', ''), '/', '')) = 14 THEN 'CNPJ'
                ELSE 'ESTRANGEIRO_PASSAPORTE'
            END AS tipo_documento,
            MAX(c.buyer_name) AS nome,
            MAX(c.buyer_email) AS email,
            MAX(c.buyer_phone_number) AS telefone
        FROM Carga c
        LEFT JOIN Clientes cli ON LTRIM(RTRIM(c.cpf)) = cli.documento_identificacao
        WHERE cli.cliente_id IS NULL AND c.cpf IS NOT NULL AND c.cpf <> ''
        GROUP BY LTRIM(RTRIM(c.cpf));

        -- 2. Inserção de Produtos Novos (Uso de LEFT JOIN para verificar existência)
        INSERT INTO Produtos (sku, nome_produto, estoque_atual)
        SELECT DISTINCT
            LTRIM(RTRIM(c.sku)) AS sku,
            MAX(c.product_name) AS nome_produto,
            0 AS estoque_atual -- Inicializa com zero até entrada de estoque
        FROM Carga c
        LEFT JOIN Produtos p ON LTRIM(RTRIM(c.sku)) = p.sku
        WHERE p.produto_id IS NULL AND c.sku IS NOT NULL AND c.sku <> ''
        GROUP BY LTRIM(RTRIM(c.sku));

        -- 3. Inserção de Pedidos (INNER JOIN com Clientes para obter cliente_id, LEFT JOIN com Pedidos para deduplicar)
        INSERT INTO Pedidos (
            order_id_marketplace, cliente_id, data_compra, data_pagamento, 
            nivel_servico_envio, nome_destinatario, endereco_envio_1, endereco_envio_2, 
            endereco_envio_3, cidade_envio, estado_envio, cep_envio, pais_envio, 
            numero_ioss, valor_total, status_pedido
        )
        SELECT 
            c.order_id AS order_id_marketplace,
            cli.cliente_id, -- Relacionamento via PK numérica!
            MAX(c.purchase_date),
            MAX(c.payments_date),
            MAX(c.ship_service_level),
            MAX(c.recipient_name),
            MAX(c.ship_address_1),
            MAX(c.ship_address_2),
            MAX(c.ship_address_3),
            MAX(c.ship_city),
            MAX(c.ship_state),
            MAX(c.ship_postal_code),
            MAX(c.ship_country),
            MAX(c.ioss_number),
            SUM(c.quantity_purchased * c.item_price) AS valor_total,
            'Pendente' AS status_pedido
        FROM Carga c
        INNER JOIN Clientes cli ON LTRIM(RTRIM(c.cpf)) = cli.documento_identificacao
        LEFT JOIN Pedidos ped ON c.order_id = ped.order_id_marketplace
        WHERE ped.pedido_id IS NULL
        GROUP BY c.order_id, cli.cliente_id;

        -- 4. Inserção dos Itens do Pedido (INNER JOIN com Pedidos e Produtos para associar pedido_id e produto_id)
        INSERT INTO ItensPedido (
            order_item_id_marketplace, pedido_id, produto_id, 
            quantidade, moeda, preco_unitario, subtotal
        )
        SELECT 
            c.order_item_id AS order_item_id_marketplace,
            ped.pedido_id,   -- PK numérica do Pedido resolvida via INNER JOIN
            prod.produto_id, -- PK numérica do Produto resolvida via INNER JOIN
            c.quantity_purchased,
            c.currency,
            c.item_price,
            (c.quantity_purchased * c.item_price) AS subtotal
        FROM Carga c
        INNER JOIN Pedidos ped ON c.order_id = ped.order_id_marketplace
        INNER JOIN Produtos prod ON LTRIM(RTRIM(c.sku)) = prod.sku
        LEFT JOIN ItensPedido item ON c.order_item_id = item.order_item_id_marketplace
        WHERE item.item_pedido_id IS NULL;

        COMMIT TRANSACTION;
        PRINT 'sp_ProcessarCarga executada com sucesso! Carga de Clientes, Produtos, Pedidos e Itens concluída.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Erro na execução de sp_ProcessarCarga: %s', 16, 1, @ErrMsg);
    END CATCH
END;

GO

-- -------------------------------------------------------------------------
-- PROCEDURE: sp_ProcessarEstoque
-- Objetivo: Atender os pedidos ordenando-os do MAIOR valor total para o MENOR.
--           Verifica se TODOS os itens do pedido possuem estoque suficiente.
--           Se SIM -> Debita o estoque, gera movimentação 'SAIDA' e status 'Atendido'.
--           Se NÃO -> Não debita estoque, registra itens em `Compras` e status 'Aguardando Compra'.
-- -------------------------------------------------------------------------
CREATE PROCEDURE sp_ProcessarEstoque
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @v_pedido_id INT;
        DECLARE @v_order_id_mkt VARCHAR(100);
        DECLARE @v_valor_total DECIMAL(10, 2);
        
        -- CURSOR 1: Lista pedidos pendentes ordenados do MAIOR valor para o MENOR valor
        -- Uso de INNER JOIN para resgatar dados do Pedido e Cliente
        DECLARE cursor_pedidos CURSOR LOCAL FORWARD_ONLY FOR
        SELECT ped.pedido_id, ped.order_id_marketplace, ped.valor_total
        FROM Pedidos ped
        INNER JOIN Clientes cli ON ped.cliente_id = cli.cliente_id
        WHERE ped.status_pedido IN ('Pendente', 'Aguardando Compra')
        ORDER BY ped.valor_total DESC;
        
        OPEN cursor_pedidos;
        FETCH NEXT FROM cursor_pedidos INTO @v_pedido_id, @v_order_id_mkt, @v_valor_total;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @pode_atender BIT = 1;
            DECLARE @v_produto_id INT;
            DECLARE @v_sku VARCHAR(100);
            DECLARE @v_qtd_necessaria INT;
            DECLARE @v_estoque_atual INT;
            
            -- CURSOR 2 (Verificação): Confere a disponibilidade de estoque para TODOS os itens do pedido
            -- Uso de INNER JOIN entre ItensPedido e Produtos via PK produto_id
            DECLARE cursor_verifica CURSOR LOCAL FORWARD_ONLY FOR
            SELECT i.produto_id, p.sku, i.quantidade, p.estoque_atual
            FROM ItensPedido i
            INNER JOIN Produtos p ON i.produto_id = p.produto_id
            WHERE i.pedido_id = @v_pedido_id;
            
            OPEN cursor_verifica;
            FETCH NEXT FROM cursor_verifica INTO @v_produto_id, @v_sku, @v_qtd_necessaria, @v_estoque_atual;
            
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @v_estoque_atual < @v_qtd_necessaria
                BEGIN
                    SET @pode_atender = 0;
                    
                    -- Registrar a falta na tabela de Compras se não estiver registrada como Pendente
                    IF NOT EXISTS (
                        SELECT 1 FROM Compras 
                        WHERE pedido_id = @v_pedido_id 
                          AND produto_id = @v_produto_id 
                          AND status_compra = 'Pendente'
                    )
                    BEGIN
                        INSERT INTO Compras (pedido_id, produto_id, quantidade_necessaria, status_compra)
                        VALUES (@v_pedido_id, @v_produto_id, (@v_qtd_necessaria - @v_estoque_atual), 'Pendente');
                    END
                END
                FETCH NEXT FROM cursor_verifica INTO @v_produto_id, @v_sku, @v_qtd_necessaria, @v_estoque_atual;
            END
            
            CLOSE cursor_verifica;
            DEALLOCATE cursor_verifica;
            
            -- Decisão: Atendimento Integral ou Aguardar Compra
            IF @pode_atender = 1
            BEGIN
                BEGIN TRANSACTION;

                -- CURSOR 3 (Efetivação): Baixa estoque e grava movimentação
                DECLARE cursor_atende CURSOR LOCAL FORWARD_ONLY FOR
                SELECT i.produto_id, i.quantidade
                FROM ItensPedido i
                WHERE i.pedido_id = @v_pedido_id;
                
                OPEN cursor_atende;
                FETCH NEXT FROM cursor_atende INTO @v_produto_id, @v_qtd_necessaria;
                
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DECLARE @saldo_ant INT;
                    DECLARE @saldo_pos INT;

                    SELECT @saldo_ant = estoque_atual FROM Produtos WHERE produto_id = @v_produto_id;
                    SET @saldo_pos = @saldo_ant - @v_qtd_necessaria;

                    -- 1. Debitar estoque
                    UPDATE Produtos 
                    SET estoque_atual = @saldo_pos
                    WHERE produto_id = @v_produto_id;

                    -- 2. Registrar histórico na tabela de Movimentação de Estoque
                    INSERT INTO MovimentacaoEstoque (
                        pedido_id, produto_id, quantidade, tipo_movimentacao, 
                        saldo_anterior, saldo_posterior
                    )
                    VALUES (
                        @v_pedido_id, @v_produto_id, @v_qtd_necessaria, 'SAIDA', 
                        @saldo_ant, @saldo_pos
                    );

                    FETCH NEXT FROM cursor_atende INTO @v_produto_id, @v_qtd_necessaria;
                END
                
                CLOSE cursor_atende;
                DEALLOCATE cursor_atende;
                
                -- 3. Atualizar Status do Pedido para 'Atendido'
                UPDATE Pedidos
                SET status_pedido = 'Atendido'
                WHERE pedido_id = @v_pedido_id;

                -- 4. Se havia solicitação na tabela Compras, altera para 'Atendido'
                UPDATE Compras
                SET status_compra = 'Atendido'
                WHERE pedido_id = @v_pedido_id;

                COMMIT TRANSACTION;
            END
            ELSE
            BEGIN
                -- Atualizar Status do Pedido para 'Aguardando Compra'
                UPDATE Pedidos
                SET status_pedido = 'Aguardando Compra'
                WHERE pedido_id = @v_pedido_id;
            END
            
            FETCH NEXT FROM cursor_pedidos INTO @v_pedido_id, @v_order_id_mkt, @v_valor_total;
        END
        
        CLOSE cursor_pedidos;
        DEALLOCATE cursor_pedidos;
        
        PRINT 'sp_ProcessarEstoque executada com sucesso! Pedidos ordenados por maior valor foram processados.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsgEst NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Erro na execução de sp_ProcessarEstoque: %s', 16, 1, @ErrMsgEst);
    END CATCH
END;

GO

-- -------------------------------------------------------------------------
-- PROCEDURE: sp_AtualizarEstoqueCompras
-- Objetivo: Processar o arquivo CSV do fornecedor (carregado em CargaCompras),
--           incrementar o estoque dos produtos entregues, registrar movimentação
--           de 'ENTRADA' e acionar o re-processamento automático dos pedidos pendentes.
-- -------------------------------------------------------------------------
CREATE PROCEDURE sp_AtualizarEstoqueCompras
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @v_sku VARCHAR(100);
        DECLARE @v_qtd_entregue INT;
        DECLARE @v_produto_id INT;
        DECLARE @v_saldo_ant INT;
        DECLARE @v_saldo_pos INT;
        
        -- CURSOR: Lendo produtos entregues pelo fornecedor
        -- Uso de INNER JOIN entre CargaCompras e Produtos via SKU para obter a PK produto_id
        DECLARE cursor_compras CURSOR LOCAL FORWARD_ONLY FOR
        SELECT cc.sku, cc.quantidade_entregue, p.produto_id, p.estoque_atual
        FROM CargaCompras cc
        INNER JOIN Produtos p ON LTRIM(RTRIM(cc.sku)) = p.sku;
        
        OPEN cursor_compras;
        FETCH NEXT FROM cursor_compras INTO @v_sku, @v_qtd_entregue, @v_produto_id, @v_saldo_ant;
        
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @v_saldo_pos = @v_saldo_ant + @v_qtd_entregue;

            -- 1. Incrementar saldo no estoque do Produto
            UPDATE Produtos
            SET estoque_atual = @v_saldo_pos
            WHERE produto_id = @v_produto_id;
            
            -- 2. Registrar movimentação de ENTRADA no estoque
            INSERT INTO MovimentacaoEstoque (
                pedido_id, produto_id, quantidade, tipo_movimentacao, 
                saldo_anterior, saldo_posterior
            )
            VALUES (
                NULL, @v_produto_id, @v_qtd_entregue, 'ENTRADA', 
                @v_saldo_ant, @v_saldo_pos
            );
            
            FETCH NEXT FROM cursor_compras INTO @v_sku, @v_qtd_entregue, @v_produto_id, @v_saldo_ant;
        END
        
        CLOSE cursor_compras;
        DEALLOCATE cursor_compras;
        
        -- Limpar a tabela de CargaCompras após o processamento
        TRUNCATE TABLE CargaCompras;

        COMMIT TRANSACTION;

        PRINT 'sp_AtualizarEstoqueCompras executada! Estoque atualizado. Tentando re-atender pedidos pendentes...';

        -- Re-executa automaticamente o processamento de estoque para atender pedidos pendentes!
        EXEC sp_ProcessarEstoque;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsgComp NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Erro em sp_AtualizarEstoqueCompras: %s', 16, 1, @ErrMsgComp);
    END CATCH
END;

GO

-- =========================================================================
-- 3. VIEWS DE RELATÓRIO E ACOMPANHAMENTO (USO EXPLICÍTO DE JOINs)
-- =========================================================================

-- 3.1. Visão Geral dos Pedidos com Clientes e Itens
CREATE VIEW vw_ResumoPedidosCompleto AS
SELECT 
    p.pedido_id,
    p.order_id_marketplace,
    c.nome AS nome_cliente,
    c.documento_identificacao,
    c.tipo_documento,
    p.data_compra,
    p.valor_total,
    p.status_pedido,
    COUNT(i.item_pedido_id) AS total_itens
FROM Pedidos p
INNER JOIN Clientes c ON p.cliente_id = c.cliente_id
LEFT JOIN ItensPedido i ON p.pedido_id = i.pedido_id
GROUP BY 
    p.pedido_id, p.order_id_marketplace, c.nome, 
    c.documento_identificacao, c.tipo_documento, p.data_compra, 
    p.valor_total, p.status_pedido;

GO

-- 3.2. Visão Detalhada de Movimentação de Estoque
CREATE VIEW vw_MovimentacaoEstoqueDetalhada AS
SELECT 
    m.movimentacao_id,
    m.data_movimentacao,
    m.tipo_movimentacao,
    prod.sku,
    prod.nome_produto,
    m.quantidade,
    m.saldo_anterior,
    m.saldo_posterior,
    p.order_id_marketplace
FROM MovimentacaoEstoque m
INNER JOIN Produtos prod ON m.produto_id = prod.produto_id
LEFT JOIN Pedidos p ON m.pedido_id = p.pedido_id;

GO

-- 3.3. Relatório de Necessidades de Compras
CREATE VIEW vw_RelatorioNecessidadeCompras AS
SELECT 
    comp.compra_id,
    p.order_id_marketplace,
    prod.sku,
    prod.nome_produto,
    comp.quantidade_necessaria,
    prod.estoque_atual AS estoque_disponivel,
    comp.status_compra,
    comp.data_registro
FROM Compras comp
INNER JOIN Pedidos p ON comp.pedido_id = p.pedido_id
INNER JOIN Produtos prod ON comp.produto_id = prod.produto_id;

GO
