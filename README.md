# mgc-vm-clone v1.0

Orquestrador para clonar uma VM Magalu Cloud entre tenants usando um QCOW2 portátil e Custom Image.

> [!IMPORTANT]
> Projeto experimental e não oficial. Não é uma ferramenta suportada oficialmente pela Magalu Cloud. Revise o código e as políticas da sua organização antes de usar em produção ou publicar externamente.


## O que a v1.0 automatiza

1. Preflight da VM de origem.
2. Snapshot de segurança opcional (habilitado por padrão).
3. Quiesce de Docker/containerd durante a captura (habilitado por padrão).
4. Export do disco inteiro da VM (`/dev/vda`) para RAW sparse e conversão para QCOW2.
5. Sanitização offline: cloud-init, machine-id, SSH host keys, authorized_keys e histórico de login.
6. Remoção de netplan/MAC herdado e validação do QCOW2.
7. Cálculo do disco mínimo da Custom Image em GB decimais (`ceil(virtual_bytes / 1e9)`).
8. Upload temporário em Object Storage e criação da Custom Image.
9. Checkpoint/resume em falhas de upload/importação.
10. Seleção automática do menor flavor da mesma família/vCPU/RAM que comporte o disco mínimo.
11. Criação da VM no tenant de destino.
12. Validação SSH, cloud-init, rede, filesystem, Docker/containerd e containers.
13. Restauração do tenant que estava ativo antes da execução.

## Instalação

```bash
git clone <URL_DO_REPOSITORIO>
cd mgc-vm-clone
chmod +x mgc-vm-clone lib/*.sh
./mgc-vm-clone --help
```

## Dependências

A máquina de operação precisa ter, entre outras ferramentas:

- `mgc`
- `jq`
- `python3`
- `qemu-img` / `qemu-nbd`
- `zstd`
- `ssh`
- `partprobe`, `partx`, `udevadm`
- `sudo`

Os helpers também fazem seus próprios preflights.

## Preflight completo

```bash
./mgc-vm-clone \
  --source-tenant <TENANT_A> \
  --source-vm <VM_ID_OU_NOME> \
  --source-region br-se1 \
  --source-ssh-host <IP_ORIGEM> \
  --target-tenant <TENANT_B> \
  --target-name <NOME_DO_CLONE> \
  --target-ssh-key <NOME_DA_CHAVE> \
  --target-az br-se1-c \
  --workdir /var/tmp/<NOME_DO_CLONE>
```

Sem `--execute` nenhum recurso é criado.

## Execução

Use o mesmo comando adicionando:

```bash
--execute
```

Por padrão a ferramenta cria um safety snapshot e interrompe Docker/containerd durante a leitura do disco. Use `--snapshot-id <UUID>` para reaproveitar um snapshot existente ou `--no-safety-snapshot` se não desejar criá-lo.

## Resume

Cada execução possui `state.json` e logs por fase:

```bash
./mgc-vm-clone --resume /var/tmp/<NOME_DO_CLONE>
```

A ferramenta reutiliza os artefatos já validados. Ela não repete export/sanitização/upload quando o checkpoint já contém esses dados.

### Custom Image com nome preso após 500/409

Se uma tentativa de criação ficar ambígua e o nome for reservado sem um ID recuperável:

```bash
./mgc-vm-clone \
  --resume /var/tmp/<NOME_DO_CLONE> \
  --new-custom-image-name <NOVO_NOME>
```

O bucket/QCOW2 já enviado é reutilizado.

## Seleção do flavor

Se o flavor de origem for, por exemplo, `BV4-8-40`, a ferramenta calcula o tamanho mínimo real do QCOW2. Um disco virtual de 40 GiB equivale a aproximadamente 42,95 GB decimais, portanto a Custom Image exige 43 GB. A seleção automática procura o menor `BV4-8-*` disponível na AZ com disco >= 43 GB — no PoC, `BV4-8-100`.

Para definir explicitamente:

```bash
--target-machine-type BV4-8-100
```

## Adoção de artefatos existentes

Para testar ou iniciar a partir de um ponto já concluído:

```bash
--adopt-final-image /caminho/imagem.qcow2
--adopt-custom-image-id <UUID>
--adopt-vm-id <UUID>
```

Isso é útil para smoke tests e para não repetir operações pesadas.

## Smoke test com uma VM já criada

```bash
./mgc-vm-clone \
  --target-tenant <TENANT_B> \
  --target-name <NOME> \
  --target-machine-type BV4-8-100 \
  --adopt-vm-id <VM_ID> \
  --validation-host <IP> \
  --workdir /var/tmp/<NOME>-v1-smoke \
  --execute
```

Nenhuma nova VM ou Custom Image é criada nesse modo; a ferramenta recupera a VM por ID e executa a validação final.

## Consultar checkpoint

```bash
./mgc-vm-clone --status /var/tmp/<NOME_DO_CLONE>
```

## Estrutura do bundle

- `mgc-vm-clone`: orquestrador v1.0.
- `lib/export.sh`: export testado no PoC.
- `lib/prepare.sh`: sanitização offline via qemu-nbd.
- `lib/fix-network.sh`: remove rede/MAC herdados.
- `lib/validate-portable.sh`: valida QCOW2 final.
- `lib/import.sh`: upload + Custom Image.
- `lib/import-resume.sh`: retomada do import sem novo upload.
- `lib/create-vm.sh`: criação da VM.
- `lib/validate-clone.sh`: validação final do clone.

Os helpers foram mantidos separados internamente para preservar as rotinas que foram testadas durante o PoC; para o operador, o ponto de entrada é somente `./mgc-vm-clone`.
