using DataFrames
using CSV
using Statistics

# ==============================================================================
# CONFIGURAÇÕES E PARÂMETROS
# ==============================================================================

CAMINHO_TABELA_LOCAIS = "MDLocais.csv"
CAMINHO_TABELA_ROTAS  = "MDArmadorRotas.csv"

# Quantidade de melhores rotas que cada POD seleciona (K >= 1)
K_ROTAS_POR_POD = 3

# Faixa central dos dados usada como min/max na normalização (0.95 = percentis 2.5% a 97.5%).
# Valores abaixo do min viram 0 e acima do max viram 1.
PERCENTIL_CENTRAL = 0.95

# Pesos da Função Multicritério (Alfa + Beta + Gama + Delta = 1.0)
ALFA  = 0.40  # Peso do Frete Efetivo
BETA  = 0.25  # Peso do Tempo de Ida
GAMA  = 0.15  # Peso do Tempo de Volta
DELTA = 0.20  # Peso da Quantidade de Destinos da Rota (mais destinos = melhor)

@assert isapprox(ALFA + BETA + GAMA + DELTA, 1.0) "Os pesos devem somar 1.0"
@assert K_ROTAS_POR_POD >= 1 "K deve ser >= 1"
@assert 0 < PERCENTIL_CENTRAL <= 1 "PERCENTIL_CENTRAL deve estar em (0, 1]"

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

# --- Métricas por linha (rota x POD) ---
function adicionar_metricas!(df::DataFrame)
    if nrow(df) == 0
        df.FRETE_EFETIVO = Float64[]
        df.T_IDA = Float64[]
        df.T_VOLTA = Float64[]
        return df
    end
    df.FRETE_EFETIVO = [
        calcular_frete_efetivo(r.V_EF, r.MAX_INTAKE, r.FRETE_POR_TON)
        for r in eachrow(df)
    ]
    df.T_IDA   = df.TEMPO_IDA
    df.T_VOLTA = df.TEMPO_IDA_VOLTA .- df.TEMPO_IDA
    return df
end

# --- Limites robustos (min/max dentro da faixa central de percentis) ---
function limites_robustos(v)
    cauda = (1 - PERCENTIL_CENTRAL) / 2
    q = quantile(Float64.(v), [cauda, 1 - cauda])
    return (q[1], q[2])
end

# Normaliza para [0,1] usando limites robustos; fora da faixa -> 0 ou 1 (clamp)
function normalizar(x, lim; inverter::Bool = false)
    lo, hi = lim
    hi == lo && return 0.0
    n = clamp((x - lo) / (hi - lo), 0.0, 1.0)
    return inverter ? 1.0 - n : n
end

# Calcula os limites a partir de um conjunto de referência (as linhas válidas)
function calcular_limites(df::DataFrame)
    return (
        frete = limites_robustos(df.FRETE_EFETIVO),
        t_ida = limites_robustos(df.T_IDA),
        t_volta = limites_robustos(df.T_VOLTA),
        qtd = limites_robustos(df.QTD_DEST_ROTA),
    )
end

# Aplica a normalização e calcula o score (menor = melhor)
function aplicar_scores!(df::DataFrame, lim)
    df.CUSTO_NORM     = [normalizar(x, lim.frete) for x in df.FRETE_EFETIVO]
    df.T_IDA_NORM     = [normalizar(x, lim.t_ida) for x in df.T_IDA]
    df.T_VOLTA_NORM   = [normalizar(x, lim.t_volta) for x in df.T_VOLTA]
    # invertido: mais destinos -> 0 (melhor), menos destinos -> 1 (pior)
    df.QTD_DEST_NORM  = [normalizar(x, lim.qtd; inverter = true) for x in df.QTD_DEST_ROTA]

    df.SCORE = (ALFA  .* df.CUSTO_NORM) .+
               (BETA  .* df.T_IDA_NORM) .+
               (GAMA  .* df.T_VOLTA_NORM) .+
               (DELTA .* df.QTD_DEST_NORM)
    return df
end

# Seleciona as K melhores rotas (menor score) para cada POD
function top_k_por_pod(df::DataFrame, k::Int)
    if nrow(df) == 0
        vazio = similar(df, 0)
        vazio.RANK_NO_POD = Int[]
        return vazio
    end
    sort!(df, [:COD_LOCAL_DESTINOS, :SCORE])
    partes = DataFrame[]
    for g in groupby(df, :COD_LOCAL_DESTINOS)
        sel = DataFrame(first(g, k))
        sel.RANK_NO_POD = collect(1:nrow(sel)) # CORRIGIDO: volta a iniciar do 1
        push!(partes, sel)
    end
    return reduce(vcat, partes)
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

    # ---------------- PODs DEPENDENTES ----------------
    com_rota   = Set(df_processado.COD_LOCAL_DESTINOS)
    aprovados  = Set(df_validas.COD_LOCAL_DESTINOS)
    reprovados = setdiff(com_rota, aprovados)

    dependentes = Set{String}(
        r.COD_LOCAL_DESTINOS for r in eachrow(df_processado)
        if (r.COD_LOCAL_DESTINOS in reprovados) && (r.CALADO_DWT < r.MIN_INTAKE)
    )
    inviaveis_outros = setdiff(reprovados, dependentes)

    println("PODs dependentes (MIN_INTAKE > CALADO): ", length(dependentes), " -> ", sort(collect(dependentes)))
    println("PODs inviáveis por outros motivos (estoque/intake): ", length(inviaveis_outros), " -> ", sort(collect(inviaveis_outros)))

    if nrow(df_validas) == 0
        error("Nenhuma rota viável encontrada após aplicar as restrições físicas.")
    end

    # 6. Frete Efetivo e Tempos
    adicionar_metricas!(df_validas)

    # 7. Normalização robusta (percentis) + 8. Score Multicritério
    limites = calcular_limites(df_validas)
    aplicar_scores!(df_validas, limites)

    # 9. K melhores rotas para CADA POD (não dependente)
    df_sel_normais = top_k_por_pod(df_validas, K_ROTAS_POR_POD)
    df_sel_normais.DEPENDENTE = fill(false, nrow(df_sel_normais))

    println("PODs atendidos pela heurística (não dependentes): ",
            length(unique(df_sel_normais.COD_LOCAL_DESTINOS)), " de ", length(aprovados))

    # ---------------- TRATAMENTO DOS DEPENDENTES ----------------
    ids_escolhidas    = Set{Int}(df_sel_normais._ROTA_ID)
    rotas_com_nao_dep = Set(df_validas._ROTA_ID)

    df_dep_all = filter(
        r -> (r.COD_LOCAL_DESTINOS in dependentes) && (r._ROTA_ID in rotas_com_nao_dep),
        df_processado
    )
    if nrow(df_dep_all) > 0
        adicionar_metricas!(df_dep_all)
        aplicar_scores!(df_dep_all, limites)
    end

    contar_aparicoes(pod, ids) = length(unique(
        df_expandido[(df_expandido.COD_LOCAL_DESTINOS .== pod) .& in.(df_expandido._ROTA_ID, Ref(ids)), :_ROTA_ID]
    ))

    n_candidatas(pod) = nrow(df_dep_all) == 0 ? 0 :
        length(unique(df_dep_all[df_dep_all.COD_LOCAL_DESTINOS .== pod, :_ROTA_ID]))
    ordem_dep = sort(collect(dependentes); by = p -> (n_candidatas(p), p))

    partes_dep = DataFrame[]
    incompletos = String[]

    for pod in ordem_dep
        ja    = contar_aparicoes(pod, ids_escolhidas)
        falta = K_ROTAS_POR_POD - ja
        if falta <= 0
            println("Dependente ", pod, ": já aparece em ", ja, " rota(s) escolhida(s) (>= K). OK.")
            continue
        end

        mascara = (df_dep_all.COD_LOCAL_DESTINOS .== pod) .& .!in.(df_dep_all._ROTA_ID, Ref(ids_escolhidas))
        cand = DataFrame(df_dep_all[mascara, :])
        if nrow(cand) > 0
            sort!(cand, :SCORE)
            unique!(cand, :_ROTA_ID)
        end

        sel = top_k_por_pod(cand, falta)
        
        # CORRIGIDO: O deslocamento do rank dos dependentes é aplicado aqui!
        if nrow(sel) > 0
            sel.RANK_NO_POD = collect((ja + 1):(ja + nrow(sel)))
        end
        
        sel.DEPENDENTE = fill(true, nrow(sel))

        println("Dependente ", pod, ": aparece em ", ja, " rota(s); faltavam ", falta,
                " -> heurística escolheu ", nrow(sel))
        if nrow(sel) < falta
            push!(incompletos, pod)
        end

        if nrow(sel) > 0
            push!(partes_dep, sel)
            union!(ids_escolhidas, sel._ROTA_ID)
        end
    end

    if !isempty(incompletos)
        println("ATENÇÃO: dependentes que não atingiram K rotas (faltam rotas com outro destino não dependente): ",
                sort(incompletos))
    end

    df_sel_dep = isempty(partes_dep) ? similar(df_sel_normais, 0) : reduce(vcat, partes_dep)

    df_selecionadas = vcat(df_sel_normais, df_sel_dep)

    # --------------------------------------------------------------------------
    # SAÍDAS
    # --------------------------------------------------------------------------

    df_selecionadas.DEST_LABEL = [
        string(r.COD_LOCAL_DESTINOS, "(#", r.RANK_NO_POD, ")", r.DEPENDENTE ? "*" : "")
        for r in eachrow(df_selecionadas)
    ]

    cols_identificadoras = [:_ROTA_ID, :COD_ARMADOR, :COD_LOCAL_ORIGENS, :MIN_INTAKE, :MAX_INTAKE,
                            :FRETE_POR_TON, :TEMPO_IDA, :TEMPO_IDA_VOLTA, :QTD_DEST_ROTA]

    df_visao_agrupada = combine(
        groupby(df_selecionadas, cols_identificadoras),
        :DEST_LABEL => (d -> join(sort(d), ", ")) => :DESTINOS_ONDE_E_TOP_K,
        nrow => :QTD_DESTINOS_ATENDIDOS
    )

    ids_rotas_otimas = sort(unique(df_selecionadas._ROTA_ID))
    df_rotas_otimas_cruas = df_rotas[ids_rotas_otimas, :]

    # CORRIGIDO: Retorna também o df_selecionadas para o CSV do Solver
    return df_visao_agrupada, df_rotas_otimas_cruas, df_selecionadas
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

println("\nCalculando rotas ótimas (K = $(K_ROTAS_POR_POD) por POD)...")

# CORRIGIDO: Agora recebe as 3 tabelas retornadas
df_agrupada, df_crua, df_solver = aplicar_heuristica(df_locais_in, df_rotas_in)

println("\n", "="^100)
println("1. VISÃO AGRUPADA POR ROTA (POD(#posição) = rota está entre as K melhores do POD; * = POD dependente):")
println("="^100)
show(stdout, df_agrupada, allrows=true, allcols=true, truncate=0)
println("\n")

println("="^100)
println("2. TABELA ORIGINAL CRUA (ROTAS SELECIONADAS COM TODOS OS SEUS DESTINOS POSSÍVEIS):")
println("="^100)
show(stdout, df_crua, allrows=true, allcols=true, truncate=0)
println("\n")

CSV.write("Saida_Visao_Agrupada.csv", df_agrupada)
CSV.write("Saida_Tabela_Crua.csv", df_crua)
println("-> Os resultados foram exportados para 'Saida_Visao_Agrupada.csv' e 'Saida_Tabela_Crua.csv'")

CSV.write("Saida_Pares_Rota_POD_Solver.csv", df_solver)
println("-> Matriz de decisão exportada para 'Saida_Pares_Rota_POD_Solver.csv'")
