# Heurística de seleção de rotas por POD

## 1. Objetivo

Para **cada POD** (porto de destino) do `MDLocais.csv`, escolher as **K melhores rotas** do `MDArmadorRotas.csv`: as de menor *score* multicritério entre as rotas fisicamente viáveis. O score combina quatro critérios: frete, tempo de ida, tempo de volta e quantidade de destinos da rota.

PODs que não comportam o volume mínimo da rota por causa do calado são tratados como **dependentes** (seção 5): eles só são atendidos como parada adicional de uma rota que já entrega em outro porto. Cada dependente também precisa aparecer em pelo menos K rotas escolhidas.

## 2. Entradas

**MDLocais.csv**: `COD_LOCAL, MAX_CARREGAMENTO, MAX_DESCARREGAMENTO, MAX_ESTOQUE, CALADO_DWT, TIPO`
Só `COD_LOCAL`, `TIPO`, `MAX_ESTOQUE` e `CALADO_DWT` entram no cálculo.

**MDArmadorRotas.csv**: `COD_ARMADOR, COD_LOCAL_ORIGENS, COD_LOCAL_DESTINOS, MIN_INTAKE, MAX_INTAKE, FRETE_POR_TON, TEMPO_IDA, TEMPO_IDA_VOLTA`

- Colunas separadas por `,`.
- Destinos dentro de uma rota separados por **`;`** (ex.: `Tarbean;Alabasta;Besaid;Paldea`). O código aceita `; , |`.
- `FRETE_POR_TON` usa vírgula decimal (`"31,22678182"`) e é convertido para número.
- Os tempos estão em **meses**. Parar em 1 ou em vários portos da rota leva o mesmo tempo.

## 3. Parâmetros (topo do `heuristica.jl`)

| Parâmetro | Padrão | Significado |
|---|---|---|
| `K_ROTAS_POR_POD` | 3 | Quantas rotas cada POD escolhe (deve ser ≥ 1). Também é o mínimo de aparições de cada dependente. |
| `PERCENTIL_CENTRAL` | 0,95 | Faixa central dos dados usada como min/max na normalização (percentis 2,5% a 97,5%). |

Pesos do score (devem somar 1,0; há um `@assert`):

| Peso | Critério | Sentido | Padrão |
|---|---|---|---|
| `ALFA` | Frete efetivo | menor é melhor | 0,40 |
| `BETA` | Tempo de ida | menor é melhor | 0,25 |
| `GAMA` | Tempo de volta | menor é melhor | 0,15 |
| `DELTA` | Quantidade de destinos da rota | **maior é melhor** | 0,20 |

## 4. Passo a passo

1. **Leitura e limpeza.** Converte números (inclusive texto com vírgula decimal), remove espaços e cria `_ROTA_ID`, um identificador único por linha original.
2. **Explosão dos destinos.** Cada rota é separada em uma linha por destino. Antes disso, registra `QTD_DEST_ROTA`, o número de destinos da rota como listada.
3. **Junção com MDLocais.** Cada par (rota, destino) recebe `MAX_ESTOQUE` e `CALADO_DWT` do POD. Destinos que não existem no MDLocais são descartados.
4. **Carga efetiva.** `V_EF = min(MAX_INTAKE, CALADO_DWT, MAX_ESTOQUE)`: o maior volume que o navio consegue descarregar naquele POD.
5. **Filtro físico.** Mantém só os pares com `V_EF >= MIN_INTAKE`. Se o POD não comporta nem o mínimo da rota, o par é inviável.
6. **Classificação dos PODs reprovados.** Veja a seção 5.
7. **Frete efetivo.** O frete base tem desconto progressivo por faixa da capacidade (`MAX_INTAKE`):

   | Faixa de carga | Fração do frete base |
   |---|---|
   | até 50% da capacidade | 100% |
   | de 50% a 75% | 90% |
   | acima de 75% | 75% |

   O frete efetivo é a média ponderada por tonelada. Exemplo: `MAX_INTAKE = 59.000`, `V_EF = 59.000`, base R$ 20/t resulta em (29.500×1 + 14.750×0,9 + 14.750×0,75) / 59.000 × 20 = **R$ 18,25/t**.
8. **Tempos.** `T_IDA = TEMPO_IDA` e `T_VOLTA = TEMPO_IDA_VOLTA − TEMPO_IDA`.
9. **Normalização robusta (0 a 1).** Para reduzir o efeito de outliers, o min e o max de cada critério não são os extremos, e sim os percentis da faixa central (`PERCENTIL_CENTRAL`). Com 0,95, `lo` é o percentil 2,5% e `hi` é o percentil 97,5%. Os limites são calculados sobre os pares viáveis (não dependentes).

   | Critério | Fórmula | Efeito |
   |---|---|---|
   | Frete, T_IDA, T_VOLTA | `clamp((x − lo) / (hi − lo), 0, 1)` | 0 = melhor |
   | Destinos | `1 − clamp((x − lo) / (hi − lo), 0, 1)` (invertida) | mais destinos → 0 |

   Valores abaixo de `lo` viram 0 e acima de `hi` viram 1. Se `hi == lo`, o critério vira 0 para todos e deixa de influenciar. Isso pode acontecer com a quantidade de destinos, que tem poucos valores distintos.
10. **Score.**
    ```
    SCORE = ALFA·frete_norm + BETA·t_ida_norm + GAMA·t_volta_norm + DELTA·destinos_norm
    ```
    Quanto menor, melhor.
11. **Seleção Top-K.** Para cada POD não dependente, ordena por score e fica com as K rotas de menor valor (ou todas, se tiver menos de K). A posição no ranking do POD é guardada como `RANK_NO_POD`.
12. **Tratamento dos dependentes.** Veja a seção 5.
13. **Saídas.** Duas tabelas e dois CSVs (seção 6).

## 5. PODs dependentes

**Definição.** Um POD é dependente se:
- não tem nenhum par (rota, POD) fisicamente viável, e
- em pelo menos uma rota, `CALADO_DWT < MIN_INTAKE`.

A ideia é que o navio entrega a carga em outros portos primeiro, fica mais leve e só depois vai até esse POD. PODs reprovados por outros motivos (estoque ou `MAX_INTAKE`) continuam inviáveis e aparecem separados no diagnóstico do console.

**Fluxo.**
1. A heurística roda normalmente (passos 7 a 11), sem os dependentes.
2. Para cada dependente, conta-se em quantas rotas **distintas**, entre as já escolhidas, ele aparece na lista de destinos.
3. Se aparece em `n ≥ K` rotas, está ok.
4. Se `n < K`, o dependente passa pela heurística para pegar as `K − n` rotas que faltam, com estas regras:
   - a restrição `V_EF >= MIN_INTAKE` é dispensada para ele;
   - a rota precisa ter pelo menos um **outro destino não dependente** e fisicamente viável;
   - rotas já escolhidas não são repetidas;
   - o score usa os **mesmos limites de normalização** dos PODs normais, então os valores são comparáveis.
5. Os dependentes são processados do mais restrito (menos rotas candidatas) para o menos restrito. As rotas que um dependente adiciona já contam para os seguintes.
6. Se não houver rotas suficientes, o dependente fica com as que existirem e o código avisa no console com "ATENÇÃO".

**Premissa.** O frete efetivo do dependente é calculado com o `V_EF` dele (menor que o `MIN_INTAKE`), não com o volume real que o navio levaria depois de descarregar nos outros portos.

## 6. Como ler as saídas

**Tabela 1: `Saida_Visao_Agrupada.csv`.** Uma linha por rota selecionada (agrupada por `_ROTA_ID`).
- `DESTINOS_ONDE_E_TOP_K`: PODs em que essa rota ficou entre as K melhores, no formato `POD(#posição)`. A posição é o ranking da rota dentro daquele POD. Um `*` no final marca POD dependente (ex.: `POD3(#1)*`).
- `QTD_DESTINOS_ATENDIDOS`: quantos PODs aparecem nessa coluna.
- `QTD_DEST_ROTA`: quantos destinos a rota tem no total.

Para dependentes, a posição `#` vale só entre as rotas escolhidas pela heurística para ele. Rotas que já o cobriam por acaso não recebem o rótulo `POD(#n)*`, mas aparecem na Tabela 2 com o destino na lista completa.

**Tabela 2: `Saida_Tabela_Crua.csv`.** As mesmas rotas, como estão no arquivo original: destinos completos com `;` e frete como texto. Tem o mesmo número de linhas da Tabela 1, mas na ordem do arquivo original (a Tabela 1 segue a ordem da seleção).

`FRETE_POR_TON` nas tabelas é o frete **base**. O score usa o frete **efetivo**, que é menor por causa dos descontos por faixa.

**Diagnósticos no console:** PODs sem rota, destinos sem correspondência no MDLocais, dependentes e inviáveis, cobertura dos dependentes (quantas rotas já tinham e quantas foram adicionadas) e avisos de dependentes que não atingiram K.

## 7. Equivalências entre critérios

Como tudo é normalizado, os pesos trocam um critério pelo outro assim, para valores dentro da faixa central. `Rf = hi_f − lo_f` e `Rq = hi_qd − lo_qd` são as amplitudes entre os percentis:

- **1 destino a mais** compensa um aumento de frete efetivo de `(DELTA/ALFA) · Rf / Rq` R$/t.
- **1 mês a mais de ida** compensa `(BETA/ALFA) · Rf / R_ida` R$/t, onde `R_ida = hi_ida − lo_ida` é a amplitude do tempo de ida em meses.

Exemplo ilustrativo, com `Rf ≈ 50`, `Rq ≈ 6` e os pesos padrão: 1 destino ≈ R$ 4/t. Os valores reais saem dos percentis calculados no código (`limites_robustos`). Valores fora da faixa são truncados em 0 ou 1, então acima do `hi` ou abaixo do `lo` essas equivalências deixam de valer.

## 8. Como rodar

```julia
import Pkg
Pkg.add(["DataFrames", "CSV"])   # uma vez só; Statistics já vem com o Julia

cd("pasta/do/projeto")            # onde estão os CSVs
include("heuristica.jl")
```

Se os CSVs não forem encontrados na pasta atual, o código usa dados fictícios de teste.
