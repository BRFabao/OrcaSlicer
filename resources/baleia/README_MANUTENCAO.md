# Baleia Connect

Esta integração mantém o fatiador e o transporte autenticado separados.

## Fluxo

1. `SelectMachineDialog::on_send_print()` deixa o Orca gerar o pacote final e
   montar as escolhas físicas de impressora e AMS.
2. Para presets Bambu no Windows, `BaleiaConnectBridge` copia o pacote para
   `BaleiaConnect/Fila` e publica um manifesto JSON de modo atômico.
3. `BaleiaConnectHelper.ps1` importa o pacote no Bambu Connect e aciona os
   controles acessíveis `Import` e `Print` uma única vez.
4. Para outros fabricantes, o caminho original do Orca continua intacto.

Trabalhos reivindicados são movidos para `Processando`. Eles nunca voltam
automaticamente para a fila, evitando impressão duplicada depois de uma queda.
Falhas vão para `Erros` e fazem o Bambu Connect aparecer para intervenção.

## Dados portáteis

O instalador portátil cria `data_dir` ao lado do executável. Na primeira
abertura, os dados do OrcaSlicer em AppData são copiados. No encerramento limpo,
`Backups` recebe uma cópia atômica; somente as cinco mais recentes permanecem.
Uma restauração automática só ocorre quando o `data_dir` está vazio ou ausente.
Os arquivos temporários do projeto usam `BaleiaConnect/Temp`, no mesmo disco do
pacote, em vez do diretório temporário do Windows.

## Atualização da base Orca

Ao portar para uma versão nova, reaplique estes pontos isolados:

- `GUI_App.cpp`: preparação do `data_dir`, início do helper e backup no fim;
- `SelectMachine.cpp`: desvio Bambu imediatamente antes de `replace_job`;
- `CMakeLists.txt`: fontes da bridge e marcador do `data_dir`;
- esta pasta `resources/baleia`.

Preserve `data_dir` e `Backups` ao substituir o restante do pacote.
