using DataFrames
using CSV

# ==============================================================================
# CONFIGURAÇÕES E PARÂMETROS
# ==============================================================================

CAMINHO_TABELA_LOCAIS = "MDLocais.csv"
CAMINHO_TABELA_ROTAS  = "MDArmadorRotas.csv"

# Pesos da Função Multicritério (Alfa + Beta + Gama + Delta = 1.0)
ALFA  = 0.40  # Peso do Frete Efetivo
BETA  = 0.25  # Peso do Tempo de Ida
GAMA  = 0.15  # Peso do Tempo de Volta
DELTA = 0.20  # Peso da Quantidade de Destinos da Rota (mais destinos = melhor)

@assert isapprox(ALFA + BETA + GAMA + DELTA, 1.0) "Os pesos devem somar 1.0"

# Separadores aceitos entre destinos dentro de uma mesma rota
SEPARADOR_DESTINOS = r"[;,|]"

# ==============================================================================
# FUNÇÕES AUXILIARES
# ==============================================================================

function para_float(x)
    if x isa Number
        return Float64(x)
    elseif x isa AbstractString
        s = replace(strip(String(x)), "," => ".")
        return parse(Float64, s)
    else
        return parse(Float64, string(x))
    end
end

function calcular_frete_efetivo(v_ef, cap_max, frete_base)
    v_ef = para_float(v_ef)
    cap_max = para_float(cap_max)
    frete_base = para_float(frete_base)

    if v_ef <= 0
        return frete_base
    end

    limite_f1 = 0.50 * cap_max
    limite_f2 = 0.75 * cap_max

    v1 = min(v_ef, limite_f1)
    v2 = max(0.0, min(v_ef, limite_f2) - limite_f1)
    v3 = max(0.0, v_ef - limite_f2)

    custo_f1 = v1 * frete_base * 1.00
    custo_f2 = v2 * frete_base * 0.90
    custo_f3 = v3 * frete_base * 0.75

    return (custo_f1 + custo_f2 + custo_f3) / v_ef
end

function separar_destinos(d)
    if d isa AbstractString
        return String.(strip.(split(String(d), SEPARADOR_DESTINOS; keepempty=false)))
    else
        return [strip(String(d))]
    end
end

# ==============================================================================
# FLUXO DA HEURÍSTICA
# ==============================================================================

function aplicar_heuristica(df_locais::DataFrame, df_rotas::DataFrame)

    locais = copy(df_locais)
    rotas  = copy(df_rotas)

    # Identificador único para mapear de volta à linha original exata
    rotas._ROTA_ID = 1:nrow(rotas)

    # 1. Normalização de tipos
    locais.COD_LOCAL   = String.(strip.(string.(locais.COD_LOCAL)))
    locais.MAX_ESTOQUE = para_float.(locais.MAX_ESTOQUE)
    locais.CALADO_DWT  = para_float.(locais.CALADO_DWT)

    rotas_proc = copy(rotas)
    rotas_proc.MIN_INTAKE      = para_float.(rotas_proc.MIN_INTAKE)
    rotas_proc.MAX_INTAKE      = para_float.(rotas_proc.MAX_INTAKE)
    rotas_proc.FRETE_POR_TON   = para_float.(rotas_proc.FRETE_POR_TON)
    rotas_proc.TEMPO_IDA       = para_float.(rotas_proc.TEMPO_IDA)
    rotas_proc.TEMPO_IDA_VOLTA = para_float.(rotas_proc.TEMPO_IDA_VOLTA)

    # 2. Desagrupamento (Explode) de destinos: aceita ; , |
    rotas_proc.COD_LOCAL_DESTINOS = [separar_destinos(d) for d in rotas_proc.COD_LOCAL_DESTINOS]
    # Quantidade de destinos da rota (o tempo é o mesmo parando em 1 ou em vários portos)
    rotas_proc.QTD_DEST_ROTA = length.(rotas_proc.COD_LOCAL_DESTINOS)
    df_expandido = flatten(rotas_proc, :COD_LOCAL_DESTINOS)
    df_expandido.COD_LOCAL_DESTINOS = String.(strip.(string.(df_expandido.COD_LOCAL_DESTINOS)))

    # ---------------- DIAGNÓSTICO 1: nomes / cobertura ----------------
    pods = filter(r -> r.TIPO == "POD", locais).COD_LOCAL
    dest_nas_rotas = Set(df_expandido.COD_LOCAL_DESTINOS)
    sem_rota = setdiff(pods, dest_nas_rotas)
    sem_match = setdiff(dest_nas_rotas, Set(locais.COD_LOCAL))
    println("PODs no MDLocais: ", length(pods))
    println("PODs sem nenhuma rota: ", length(sem_rota), " -> ", sort(collect(sem_rota)))
    println("Destinos nas rotas sem match no MDLocais: ", length(sem_match), " -> ", sort(collect(sem_match)))

    # 3. Cruzamento com Tabela de Locais (PODs)
    df_processado = innerjoin(
        df_expandido,
        locais,
        on = :COD_LOCAL_DESTINOS => :COD_LOCAL
    )

    # 4. Carga Efetiva Máxima (V_ef)
    df_processado.V_EF = min.(
        df_processado.MAX_INTAKE,
        df_processado.CALADO_DWT,
        df_processado.MAX_ESTOQUE
    )

    # 5. Restrições Físicas
    df_validas = filter(row -> row.V_EF >= row.MIN_INTAKE, df_processado)

    # ---------------- DIAGNÓSTICO 2: reprovados pela restrição física ----------------
    com_rota   = Set(df_processado.COD_LOCAL_DESTINOS)
    aprovados  = Set(df_validas.COD_LOCAL_DESTINOS)
    reprovados = setdiff(com_rota, aprovados)
    println("PODs reprovados só por V_EF < MIN_INTAKE: ", length(reprovados), " -> ", sort(collect(reprovados)))

    if nrow(df_validas) == 0
        error("Nenhuma rota viável encontrada após aplicar as restrições físicas.")
    end

    # 6. Frete Efetivo e Tempos
    df_validas.FRETE_EFETIVO = [
        calcular_frete_efetivo(row.V_EF, row.MAX_INTAKE, row.FRETE_POR_TON)
        for row in eachrow(df_validas)
    ]

    df_validas.T_IDA   = df_validas.TEMPO_IDA
    df_validas.T_VOLTA = df_validas.TEMPO_IDA_VOLTA .- df_validas.TEMPO_IDA

    # 7. Normalização Min-Max (0 a 1)
    min_f, max_f   = extrema(df_validas.FRETE_EFETIVO)
    min_ti, max_ti = extrema(df_validas.T_IDA)
    min_tv, max_tv = extrema(df_validas.T_VOLTA)
    min_qd, max_qd = extrema(df_validas.QTD_DEST_ROTA)

    norm_f(x)  = max_f == min_f ? 0.0 : (x - min_f) / (max_f - min_f)
    norm_ti(x) = max_ti == min_ti ? 0.0 : (x - min_ti) / (max_ti - min_ti)
    norm_tv(x) = max_tv == min_tv ? 0.0 : (x - min_tv) / (max_tv - min_tv)
    # invertido: mais destinos -> 0 (melhor), menos destinos -> 1 (pior)
    norm_qd(x) = max_qd == min_qd ? 0.0 : (max_qd - x) / (max_qd - min_qd)

    df_validas.CUSTO_NORM   = norm_f.(df_validas.FRETE_EFETIVO)
    df_validas.T_IDA_NORM   = norm_ti.(df_validas.T_IDA)
    df_validas.T_VOLTA_NORM = norm_tv.(df_validas.T_VOLTA)
    df_validas.QTD_DEST_NORM = norm_qd.(df_validas.QTD_DEST_ROTA)

    # 8. Score Multicritério
    df_validas.SCORE = (ALFA .* df_validas.CUSTO_NORM) .+
                       (BETA .* df_validas.T_IDA_NORM) .+
                       (GAMA .* df_validas.T_VOLTA_NORM) .+
                       (DELTA .* df_validas.QTD_DEST_NORM)

    # 9. Rota de menor score para CADA destino (POD)
    sort!(df_validas, [:COD_LOCAL_DESTINOS, :SCORE])
    df_selecionadas_puras = unique(df_validas, :COD_LOCAL_DESTINOS)

    println("PODs atendidos pela heurística: ", nrow(df_selecionadas_puras), " de ", length(pods))

    # --------------------------------------------------------------------------
    # SAÍDAS
    # --------------------------------------------------------------------------

    # Tabela 1: Agrupada por rota (1 linha por rota vencedora, via _ROTA_ID)
    cols_identificadoras = [:_ROTA_ID, :COD_ARMADOR, :COD_LOCAL_ORIGENS, :MIN_INTAKE, :MAX_INTAKE,
                            :FRETE_POR_TON, :TEMPO_IDA, :TEMPO_IDA_VOLTA, :QTD_DEST_ROTA]

    df_visao_agrupada = combine(
        groupby(df_selecionadas_puras, cols_identificadoras),
        :COD_LOCAL_DESTINOS => (d -> join(sort(unique(d)), ", ")) => :DESTINOS_ONDE_E_OTIMA,
        nrow => :QTD_DESTINOS_ATENDIDOS
    )

    # Tabela 2: linhas originais das rotas campeãs
    ids_rotas_otimas = unique(df_selecionadas_puras._ROTA_ID)
    df_rotas_otimas_cruas = df_rotas[ids_rotas_otimas, :]

    return df_visao_agrupada, df_rotas_otimas_cruas
end

# ==============================================================================
# EXECUÇÃO E EXIBIÇÃO
# ==============================================================================

if isfile(CAMINHO_TABELA_LOCAIS) && isfile(CAMINHO_TABELA_ROTAS)
    println("Lendo tabelas de entrada dos arquivos CSV...")
    df_locais_in = CSV.read(CAMINHO_TABELA_LOCAIS, DataFrame)
    df_rotas_in  = CSV.read(CAMINHO_TABELA_ROTAS, DataFrame)
else
    println("Arquivos CSV não encontrados. Criando dados fictícios para teste...")

    df_locais_in = DataFrame(
        COD_LOCAL = ["POL1", "POD1", "POD2", "POD3"],
        MAX_CARREGAMENTO = [50000, 0, 0, 0],
        MAX_DESCARREGAMENTO = [0, 10000, 12000, 8000],
        MAX_ESTOQUE = [100000, 40000, 60000, 30000],
        CALADO_DWT = [60000, 45000, 55000, 35000],
        TIPO = ["POL", "POD", "POD", "POD"]
    )

    df_rotas_in = DataFrame(
        COD_ARMADOR = ["ARM1", "ARM2", "ARM1"],
        COD_LOCAL_ORIGENS = ["POL1", "POL1", "POL1"],
        COD_LOCAL_DESTINOS = ["POD1;POD2;POD3", "POD2;POD3", "POD1;POD3"],
        MIN_INTAKE = [10000, 15000, 12000],
        MAX_INTAKE = [50000, 50000, 40000],
        FRETE_POR_TON = ["10.0", "9.5", "11.0"],
        TEMPO_IDA = [1.0, 2.0, 1.5],
        TEMPO_IDA_VOLTA = [2.5, 4.0, 3.0]
    )
end

println("\nCalculando rotas ótimas...")
df_agrupada, df_crua = aplicar_heuristica(df_locais_in, df_rotas_in)

println("\n", "="^100)
println("1. VISÃO AGRUPADA POR ROTA (DESTINOS ONDE A ROTA FOI SELECIONADA COMO ÓTIMA):")
println("="^100)
show(stdout, df_agrupada, allrows=true, allcols=true, truncate=0)
println("\n")

println("="^100)
println("2. TABELA ORIGINAL CRUA (ROTAS VENCEDORAS COM TODOS OS SEUS DESTINOS POSSÍVEIS):")
println("="^100)
show(stdout, df_crua, allrows=true, allcols=true, truncate=0)
println("\n")

CSV.write("Saida_Visao_Agrupada.csv", df_agrupada)
CSV.write("Saida_Tabela_Crua.csv", df_crua)
println("-> Os resultados foram exportados para 'Saida_Visao_Agrupada.csv' e 'Saida_Tabela_Crua.csv'")