# Heurística de seleção de rotas por POD

## 1. Objetivo

Para **cada POD** (porto de destino) do `MDLocais.csv`, escolher **uma única rota** do `MDArmadorRotas.csv`: a de menor *score* multicritério entre as rotas fisicamente viáveis. O score combina quatro critérios: frete, tempo de ida, tempo de volta e quantidade de destinos da rota.

## 2. Entradas

**MDLocais.csv**: `COD_LOCAL, MAX_CARREGAMENTO, MAX_DESCARREGAMENTO, MAX_ESTOQUE, CALADO_DWT, TIPO`
169 PODs, 3 POLs e 9 fábricas. Só `MAX_ESTOQUE` e `CALADO_DWT` entram no cálculo.

**MDArmadorRotas.csv**: `COD_ARMADOR, COD_LOCAL_ORIGENS, COD_LOCAL_DESTINOS, MIN_INTAKE, MAX_INTAKE, FRETE_POR_TON, TEMPO_IDA, TEMPO_IDA_VOLTA`

- Colunas separadas por `,`.
- Destinos dentro de uma rota separados por **`;`** (ex.: `Tarbean;Alabasta;Besaid;Paldea`). O código aceita `; , |`.
- `FRETE_POR_TON` usa vírgula decimal (`"31,22678182"`) e é convertido para número.
- Os tempos estão em **meses**. Parar em 1 ou em vários portos da rota leva o mesmo tempo.

## 3. Parâmetros (topo do `heuristica.jl`)

| Peso | Critério | Sentido |
|---|---|---|
| `ALFA` | Frete efetivo | menor é melhor |
| `BETA` | Tempo de ida | menor é melhor |
| `GAMA` | Tempo de volta | menor é melhor |
| `DELTA` | Quantidade de destinos da rota | **maior é melhor** |

Os quatro devem somar 1,0 (há um `@assert`). Valores padrão do arquivo: 0,40 / 0,25 / 0,15 / 0,20.

## 4. Passo a passo

1. **Leitura e limpeza.** Converte números (inclusive texto com vírgula decimal), remove espaços e cria `_ROTA_ID`, um identificador único por linha original.
2. **Explosão dos destinos.** Cada rota é separada em uma linha por destino. Antes disso, registra `QTD_DEST_ROTA`, o número de destinos da rota como listada.
3. **Junção com MDLocais.** Cada par (rota, destino) recebe `MAX_ESTOQUE` e `CALADO_DWT` do POD. Destinos que não existem no MDLocais são descartados.
4. **Carga efetiva.** `V_EF = min(MAX_INTAKE, CALADO_DWT, MAX_ESTOQUE)`: o maior volume que o navio consegue descarregar naquele POD.
5. **Filtro físico.** Mantém só os pares com `V_EF >= MIN_INTAKE`. Se o POD não comporta nem o mínimo da rota, ela é inviável para esse POD.
6. **Frete efetivo.** O frete base tem desconto progressivo por faixa da capacidade (`MAX_INTAKE`):

   | Faixa de carga | Fração do frete base |
   |---|---|
   | até 50% da capacidade | 100% |
   | de 50% a 75% | 90% |
   | acima de 75% | 75% |

   O frete efetivo é a média ponderada por tonelada. Exemplo: `MAX_INTAKE = 59.000`, `V_EF = 59.000`, base R$ 20/t resulta em (29.500×1 + 14.750×0,9 + 14.750×0,75) / 59.000 × 20 = **R$ 18,25/t**.
7. **Tempos.** `T_IDA = TEMPO_IDA` e `T_VOLTA = TEMPO_IDA_VOLTA − TEMPO_IDA`.
8. **Normalização min-max (0 a 1)** sobre todos os pares viáveis:

   | Critério | Fórmula | Efeito |
   |---|---|---|
   | Frete, T_IDA, T_VOLTA | `(x − min) / (max − min)` | 0 = melhor |
   | Destinos | `(max − x) / (max − min)` (invertida) | mais destinos → 0 |

   Se `max == min`, o critério vira 0 para todos e deixa de influenciar.
9. **Score.**
   ```
   SCORE = ALFA·frete_norm + BETA·t_ida_norm + GAMA·t_volta_norm + DELTA·destinos_norm
   ```
   Quanto menor, melhor.
10. **Seleção.** Para cada POD, ordena por score e fica com a rota de menor valor.
11. **Saídas.** Duas tabelas e dois CSVs (seção 5).

## 5. Como ler as saídas

**Tabela 1: `Saida_Visao_Agrupada.csv`.** Uma linha por rota vencedora (agrupada por `_ROTA_ID`).
- `DESTINOS_ONDE_E_OTIMA`: PODs em que essa rota foi a melhor.
- `QTD_DESTINOS_ATENDIDOS`: quantos são esses PODs.
- `QTD_DEST_ROTA`: quantos destinos a rota tem no total. `QTD_DESTINOS_ATENDIDOS` é sempre menor ou igual, porque a rota pode perder em alguns de seus destinos para outra rota.

**Tabela 2: `Saida_Tabela_Crua.csv`.** As mesmas rotas, como estão no arquivo original: destinos completos com `;` e frete como texto. Tem correspondência 1 para 1 com a Tabela 1 (52 linhas cada).

`FRETE_POR_TON` nas tabelas é o frete **base**. O score usa o frete **efetivo**, que é menor por causa dos descontos por faixa.

## 6. Equivalências entre critérios

Como tudo é normalizado, os pesos trocam um critério pelo outro assim (`Rf = max_f − min_f`, `Rq = max_qd − min_qd`):

- **1 destino a mais** compensa um aumento de frete efetivo de `(DELTA/ALFA) · Rf / Rq` R$/t.
- **1 mês a mais de ida** compensa `(BETA/ALFA) · Rf` R$/t.

Exemplo ilustrativo, com `Rf ≈ 50`, `Rq ≈ 6` e os pesos padrão: 1 destino ≈ R$ 4/t e 1 mês ≈ R$ 31/t. Os valores reais de `Rf` e `Rq` saem de `extrema(...)` no código.
