# LIMINAL

![LIMINAL Banner](assets/ui/liminal_banner.png)

### Made by João Afonso

Jogo de terror psicológico na primeira pessoa inspirado nas Backrooms. Acordas
num piso de escritórios impossível, visto através de um sinal de televisão que
se degrada à medida que o perigo aumenta. Encontra cinco latas de Snus, ativa o
botão de emergência e localiza a saída. Não estás sozinho.

Sem mapa nem lanterna. O som é o teu radar.

## Jogar no Windows

Descarrega `LIMINAL-windows.zip` em
[Releases](https://github.com/joaoafonso2004/LIMINAL/releases), extrai o ficheiro
e abre `LIMINAL.exe`. Não necessita de instalação nem de um `.pck` separado.

## Controlos

| Tecla | Ação |
|---|---|
| W A S D | Movimento |
| Rato | Olhar |
| Shift | Sprint |
| Ctrl / C | Agachar |
| E | Interagir |
| Q | Gritar no co-op |
| Esc | Pausa / menu local no co-op |

## Co-op (2–4 jogadores)

O co-op usa um relay público: não é preciso abrir portas no router nem estar na
mesma rede.

1. O host escolhe **CO-OP**, o tamanho do grupo e cria a sala.
2. O jogo mostra um código que deve ser enviado aos restantes jogadores.
3. Os amigos escrevem o código em **CODE** e selecionam **JOIN**.
4. A partida começa quando a sala fica cheia.

### Regras principais

- O labirinto, os Snus e o progresso dos botões de emergência são partilhados.
- Os jogadores começam separados; o grito 3D ajuda a reencontrar a equipa.
- Um jogador caído pode gritar e ser reanimado durante a janela de revive.
- Quando essa janela termina, passa a observar os colegas ainda vivos.
- Sustos e aparições permanecem individuais para cada jogador.
- Abrir o menu em co-op não pausa a simulação para os outros jogadores.

## Desenvolvimento

Projeto Godot 4, testado com Godot 4.6.1.

1. Instala o [Godot 4.6+](https://godotengine.org/download).
2. Abre `project.godot`.
3. Executa a cena principal com `F5`.

Os valores de ritmo, dificuldade e atmosfera estão centralizados em
[`scripts/tuning.gd`](scripts/tuning.gd).

### Exportar o executável

O preset **Windows Desktop** está incluído e incorpora o `.pck` dentro do `.exe`.

```powershell
godot --headless --path . --export-release "Windows Desktop" build/LIMINAL.exe
```

## Créditos

- Criação e direção: **João Afonso**
- Sons da entidade: **juanjo_sound** — *Backrooms Entity SFX (Vol. 1)*
- Caveat font: SIL Open Font License 1.1
