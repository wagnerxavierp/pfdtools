# Algoritmo de bloqueio de escrita forense (Windows)

## Contexto

Em perícia de DVR/NVR, o disco de evidência costuma ser removido e conectado a uma estação Windows via adaptador **USB-SATA/USB-NVMe**. Esses adaptadores frequentemente usam **UAS/UASP** (USB Attached SCSI), e o registro clássico `StorageDevicePolicies\WriteProtect` **não cobre UAS de forma confiável**.

Bloqueio em **software** é um controle compensatório quando não há hardware write-blocker. Não substitui o bloqueador físico para garantia metrológica plena; deve ser **validado** na combinação Windows + adaptador + tipo de mídia antes de tocar evidência.

## Ferramentas e referências pesquisadas

| Abordagem | Fonte / ferramenta | Cobertura | Limitação |
|-----------|-------------------|-----------|-----------|
| `WriteProtect=1` | SANS DFIR workstation hardening; XP SP2+ | USB BOT / flash “removable” | Falha ou é inconsistente em UAS/HDD externos |
| `RemovableStorageDevices\...\Deny_Write` | GPO “Removable Disks: Deny write access” | Removíveis + melhor cobertura UAS | Política de SO; timing de plug |
| `EnabledDenyGP` + SDDL | digitalsleuth/Registry-Write-Block | Disk + Volume GUIDs | Complexo; requer admin |
| `attributes disk set readonly` | diskpart (Microsoft) | Disco já enumerado | Por disco; após conexão |
| `automount disable` | SANS / diskpart / `MountMgr\NoAutoMount` | Evita montagem automática | Não bloqueia I/O bruto sozinho |
| Filter driver (kernel) | usbWriteLock (acadêmico) | Mais profundo | Assinatura de driver, complexidade |
| Live Linux forense | CAINE, Tsurugi | Write-block por padrão no boot | Alternativa operacional forte |

Projetos open-source relevantes: [digitalsleuth/Registry-Write-Block](https://github.com/digitalsleuth/Registry-Write-Block), [forensicmike/USBWriteBlockingW10](https://github.com/forensicmike/USBWriteBlockingW10), NIST CFTT (software write blockers).

## GUIDs usados

| GUID | Interface |
|------|-----------|
| `{53f56307-b6bf-11d0-94f2-00a0c91efb8b}` | `GUID_DEVINTERFACE_DISK` |
| `{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}` | `GUID_DEVINTERFACE_VOLUME` |

## Algoritmo em camadas (PFD-WriteBlocker)

```
┌─────────────────────────────────────────────────────────────┐
│  ENTRADA: operador eleva PowerShell, SEM evidência plugada  │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  CAMADA A — Política Removable Storage                      │
│  HKLM\SOFTWARE\Policies\Microsoft\Windows\                  │
│    RemovableStorageDevices\{Disk,Volume}\Deny_Write = 1     │
│  + Custom\Deny_Write\List com ambos GUIDs                   │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  CAMADA B — WriteProtect clássico                           │
│  HKLM\SYSTEM\CurrentControlSet\Control\                     │
│    StorageDevicePolicies\WriteProtect = 1                   │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  CAMADA C — EnabledDenyGP (Disk + Volume)                   │
│  EnumerateDevices=1, AccessBitMask=0,                       │
│  SecurityDescriptor = SDDL negando escrita a IU             │
│  + HotplugSecurityDescriptor restritivo                     │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  CAMADA D — Automount OFF + AutoRun OFF                     │
│  diskpart: automount disable                                │
│  MountMgr\NoAutoMount = 1                                   │
│  Explorer\NoDriveTypeAutoRun = 255                          │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  VALIDAÇÃO (mídia NÃO-evidência, adaptador idêntico)        │
│  Tentativa de WriteAllText / CreateFile WRITE               │
│  Esperado: ACCESS DENIED / falha de escrita                 │
│  Log JSONL de cadeia de custódia                            │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  PÓS-CONEXÃO DA EVIDÊNCIA                                   │
│  CAMADA E — attributes disk set readonly (diskpart)         │
│  Aquisição forense somente leitura                          │
└─────────────────────────────────────────────────────────────┘
```

### Pseudocódigo

```
function EnableWriteBlock():
    require Administrator
    assert no_evidence_connected  # procedimento operacional

    set Deny_Write(Disk GUID) = 1
    set Deny_Write(Volume GUID) = 1
    set CustomDenyWriteList = {Disk, Volume}
    set StorageDevicePolicies.WriteProtect = 1
    set EnabledDenyGP(Disk)  = {Enumerate=1, AccessBitMask=0, SDDL=deny_write_IU}
    set EnabledDenyGP(Volume)= {Enumerate=1, AccessBitMask=0, SDDL=deny_write_IU}
    set HotplugSecurityDescriptor = RESTRICTED_BINARY
    set NoDriveTypeAutoRun = 255
    diskpart automount disable
    sleep 2s   # janela de aplicação do PnP/storage stack

    log custody(event=enable, status=snapshot())
    return Status()

function Validate(testDisk):
    require Status().layers >= threshold
    require testDisk != systemDisk
    set disk attributes readonly on testDisk
    for each mounted volume OR physical device:
        attempt write probe
        record blocked? and exception
    verdict = PASS iff all probes blocked
    log custody(event=validation, verdict)
    return verdict

function ProtectEvidenceDisk(n):
    require n != systemDisk
    diskpart: select disk n; attributes disk set readonly
    log custody(event=disk_readonly_set)
```

## Por que em camadas?

1. **WriteProtect** sozinho é insuficiente para muitos HDDs externos UAS (cenário DVR).
2. **Deny_Write / EnabledDenyGP no GUID Disk** atacam a classe de dispositivo de disco, não só “volume removível”.
3. **Automount OFF** reduz montagem e atualizações de FS (ex.: journal NTFS) antes da aquisição.
4. **Readonly por disco** reforça após a evidência já estar enumerada.
5. **Validação + log** documentam a eficácia naquele hardware — requisito de boa prática forense.

## O que este método NÃO garante

- Escrita por drivers/ferramentas com SCSI passthrough / I/O bruto fora do caminho de política.
- Dispositivos já montados **antes** do Enable (desconecte e reconecte).
- eSATA/FireWire/Thunderbolt sem o mesmo caminho USBSTOR/UAS.
- Equivalência jurídica automática a um bloqueador físico certificado.

## Fluxo operacional sugerido (DVR/NVR)

1. Estação limpa / conta perito; executar `Enable`.
2. Conectar **somente** adaptador + disco de **teste** idêntico; `Validate -DiskNumber N`.
3. Se PASS: desconectar teste; conectar disco evidência; `ProtectDisk -DiskNumber N`.
4. Adquirir imagem (FTK Imager, Arsenal Image Mounter + ferramenta, Guymager em Linux, etc.).
5. Calcular hash da evidência/imagem; registrar no laudo.
6. `Disable` apenas ao encerrar a sessão de perícia.
