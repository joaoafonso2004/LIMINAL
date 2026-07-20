# LIMINAL — Implementation Plan (Finalizar o Level 0)

Backlog consolidado para fechar o primeiro nível. Prioridade e esforço marcados.

---

## 🔴 Blockers — resolver antes de considerar "acabado"

| # | Item | Estado | Esforço |
|---|---|---|---|
| B1 | **Verificar o gameplay loop completo de ponta a ponta** — spawn → 5 snus → botão(ões) de emergência → porta de saída → ending de fuga. | ✅ Verificado | Médio |
| B2 | **Teste de co-op a dois clientes reais** — round-robin de sustos, texturas dos teammates, `extract_activate`, proteção de pausa. Correto no código, necessita teste humano final. | Por testar (tarefa humana) | — |
| B3 | **2º passe de auditoria** a `world_content_manager.gd` e `mimic_controller.gd`. | ✅ Auditado | Médio |

## 🟠 Correções de robustez (da auditoria)

| # | Item | Estado | Esforço |
|---|---|---|---|
| R2 | **Guard de rede na troca de cena** — `if not is_inside_tree(): return` no topo do `_on_net_message`. | ✅ Feito | Baixo |
| R3 | **Timeout de segurança no `play_sfx_3d`** — libertar o `AudioStreamPlayer3D` com timer de fallback. | ✅ Feito | Baixo |
| R4 | **`duplicate()` antes de mutar `loop`** nos MP3 partilhados (`audio_manager` e `game_world`). | ✅ Feito | Baixo |

## 🟡 Polimento que se nota

| # | Item | Estado | Esforço |
|---|---|---|---|
| P1 | **Orientação do botão de emergência** — painel vertical montado limpo na parede. | ✅ Feito | Baixo-Médio |
| P2 | **Ecrã de loading** — campo escuro atmosférico com barra dourada. | ✅ Feito | Baixo |

## 🟢 Decisões (opcionais / pós-teste)

| # | Item | A decidir |
|---|---|---|
| D1 | **Brilho/gama** | Calibração segura de alcance apertado (só mexe em tons médios, nunca levanta os pretos) **OU** deixar de fora? |
| D2 | **Sprint** | Confirmar se há **stamina**; se não, decidir se adicionamos (sprint infinito trivializa as perseguições). |
| D3 | **Reforço de objetivo** | HUD transitório atual chega, ou lembrete diegético (nota/relógio)? |
| D4 | **Rebinding de teclas** | Incluir no Level 0 ou deixar para depois? |

## ✅ Já feito e verificado

- Paredes da fronteira com colisão (não cais do mapa) — causa raiz + rede de segurança
- Texturas dos players em co-op não-pretas (`metallic 1.0 → 0.0`)
- Lógica de rede co-op revista (round-robin de sustos inclui o host)
- Mapa segmentado estilo Backrooms (salas fechadas + halls abertos com pilares)
- Preload do snus corrigido (`SNUS.glb`)
- Proteção de pausa em co-op (jogador não-alvo com menu aberto)
- Cache de meshes no `entity_director` (fades de alpha sem `find_children` por frame)
- Auditado `world_content_manager.gd` e `mimic_controller.gd`
- Adicionado guard de rede `is_inside_tree()` na recepção de mensagens
- Adicionado timeout de segurança nos `AudioStreamPlayer3D` para evitar leaks
- Adicionado `duplicate()` em MP3s antes de ativar `loop` em recursos partilhados
- Botão de emergência reorientado como painel vertical limpo na parede
- Ecrã de loading renovado para tema atmosférico escuro

---

## 📦 Release (no fim)

- Commit + push de tudo
- Gerar `.exe` novo
- Nova release no GitHub
