# pfdtools — PFD WriteBlocker

Ferramenta de **bloqueio de escrita em software** para estação Windows em perícia forense digital (DVR/NVR, pendrives, HDD via USB), com **interface gráfica** de gestão do fluxo.

> **Aviso:** software write-blocker **não substitui** hardware write-blocker. Valide sempre em mídia de teste com o **mesmo adaptador** antes da evidência.

## Interface gráfica (recomendado)

Execute (solicita UAC de Administrador automaticamente):

`WriteBlocker\PFD-WriteBlocker.exe`

Ou o atalho `WriteBlocker\Iniciar-WriteBlocker.cmd`.

Para recompilar o `.exe`:

```bat
WriteBlocker\build\Build-Exe.cmd
```

Na GUI você gerencia:

1. Metadados do caso / operador  
2. Ativar / desativar bloqueio em camadas  
3. Status de cada camada  
4. Inventário de discos  
5. Validação em mídia de teste  
6. Readonly do disco de evidência  
7. Automount ON/OFF  
8. Log de atividade + arquivo de custódia  

## CLI

```powershell
.\PFD-WriteBlocker.ps1 Enable -CaseId "2026-DVR-001"
.\PFD-WriteBlocker.ps1 Status
.\PFD-WriteBlocker.ps1 Disks
.\PFD-WriteBlocker.ps1 Validate -DiskNumber 2
.\PFD-WriteBlocker.ps1 ProtectDisk -DiskNumber 2
.\PFD-WriteBlocker.ps1 Disable
.\PFD-WriteBlocker.ps1 Gui
```

## Documentação do algoritmo

[docs/ALGORITMO-WRITE-BLOCK.md](docs/ALGORITMO-WRITE-BLOCK.md)

## Estrutura

```
pfdtools/
├── README.md
├── docs/ALGORITMO-WRITE-BLOCK.md
└── WriteBlocker/
    ├── Iniciar-WriteBlocker.cmd      # abre a GUI (UAC)
    ├── PFD-WriteBlocker-GUI.ps1      # interface gráfica
    ├── PFD-WriteBlocker.ps1          # CLI
    ├── PFD-WriteBlocker.Core.psm1    # núcleo compartilhado
    └── logs/
```
