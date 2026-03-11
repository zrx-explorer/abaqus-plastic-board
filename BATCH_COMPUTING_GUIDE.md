# Abaqus 批量计算使用说明

## 一、生成 tasks.txt

### 基本用法
```bash
python generate_tasks.py <STP 文件根目录> -o tasks.txt
```

### 示例
```bash
# 扫描 /public/data/models 目录下所有 step 文件
python generate_tasks.py /public/data/models -o tasks.txt

# 只模拟 x 和 z 方向
python generate_tasks.py /public/data/models -o tasks.txt -d xz

# 预览不生成文件
python generate_tasks.py /public/data/models --dry-run
```

### 输出格式
```
/public/data/models/part1.step x
/public/data/models/part1.step y
/public/data/models/part1.step z
/public/data/models/subfolder/part2.step x
...
```

---

## 二、单机测试（slurm-test.sh）

**适用场景：** 测试单个 STP 文件，验证环境和参数配置

### 基本命令
```bash
sbatch slurm-test.sh
```

### 自定义参数（通过环境变量）
```bash
# 设置输入文件和参数
export PLASIM_INFILE="/path/to/your/model.step"
export PLASIM_OUTDIR="/custom/output/path"  # 可选，默认使用 ../res-test
export PLASIM_DIRECTION="z"                  # x, y, or z
export PLASIM_NCPU="8"                       # CPU 数量
export PLASIM_YOUNG_MODULE="28700"           # 杨氏模量 (MPa)
export PLASIM_POISSON_RATIO="0.3"            # 泊松比
export PLASIM_YIELD_STRESS="221.0"           # 屈服强度 (MPa)
export PLASIM_ROU="2.7e-09"                  # 密度 (t/mm³)
export PLASIM_EARLYSTOP="-e"                 # 早停模式
export PLASIM_DEBUG=""                       # 调试模式（留空则自动清理中间文件）

# 提交任务
sbatch slurm-test.sh
```

### 输出目录结构
```
../res-test/  # 相对于脚本所在目录的上一级
└── Array_3x3x3_S4_D8_12_12_12_E28700_Y221.0_z/
    ├── info.json                                    # 参数配置
    ├── Array_3x3x3_S4_D8_12_12_12_E28700_Y221.0_z.csv    # 成功时的结果
    └── (Abaqus 中间文件，成功后自动删除)
```

### 查看日志
```bash
# SLURM 日志
cat slurm-*.out

# 查看结果
ls -la ../res-test/
```

### 清理测试
```bash
# 删除测试输出
rm -rf ../res-test/
```

---

## 三、提交批量任务

### 基本命令
```bash
sbatch sbatch.sh \
    -i tasks.txt \
    -o results \
    -E 28700 \
    -P 0.3 \
    -Y 221.0 \
    -R 2.7e-09
```

### 完整参数
| 参数 | 含义 | 默认值 |
|------|------|--------|
| `-i` | tasks.txt 文件路径 | 必需 |
| `-o` | 输出根目录 | 必需 |
| `-E` | 杨氏模量 (MPa) | 28700 |
| `-P` | 泊松比 | 0.3 |
| `-Y` | 屈服强度 (MPa) | 221.0 |
| `-R` | 密度 (t/mm³) | 2.7e-09 |
| `-l` | 启用负载均衡模式 | 关闭 |

---

## 四、任务分配策略

### 当前配置
- **SLURM Array**: 0-999 (1000 个任务)
- **每个模型**: 3 个方向 (x, y, z)
- **推荐模型数**: 2000 个左右

### 任务分配示例
```
总任务数 = 2000 模型 × 3 方向 = 6000 任务
Array 数量 = 1000
每 Array 任务数 = 6000 / 1000 = 6 任务
```

### Array ID 分配
```
Array 0:   tasks.txt 第 1-6 行
Array 1:   tasks.txt 第 7-12 行
Array 2:   tasks.txt 第 13-18 行
...
Array 999: tasks.txt 第 5995-6000 行
```

---

## 五、输出目录结构

```
results/
├── part1.x/
│   └── part1_E28700_Y221.0_x/
│       ├── info.json
│       ├── part1_E28700_Y221.0_x.csv    # 成功
│       └── (Abaqus 中间文件，成功后删除)
├── part1.y/
│   └── part1_E28700_Y221.0_y/
│       └── part1_E28700_Y221.0_y.csv
├── part1.z/
│   └── part1_E28700_Y221.0_z/
│       └── part1_E28700_Y221.0_z.csv
...
```

---

## 六、任务状态管理

### 查看队列
```bash
# 查看所有任务
squeue -u $USER

# 查看特定任务
squeue -j <job_id>

# 查看剩余时间
squeue -u $USER --format="%.18i %.9P %.20j %.8T %.10M %.6D %.20S %R"
```

### 取消任务
```bash
# 取消所有
scancel -u $USER

# 取消特定作业 ID
scancel <job_id>

# 取消特定 Array 范围
scancel <job_id>_[0-100]
```

---

## 七、日志查看

```bash
# 查看所有日志
ls slurm.logs/

# 查看特定 Array 日志
cat slurm.logs/log_<job_id>_<array_id>.txt

# 实时监控最新日志
tail -f slurm.logs/log_<job_id>_<array_id>.txt
```

---

## 八、检查结果

### 统计成功/失败任务
```bash
# 统计成功 CSV 数量
find results -name "*.csv" ! -name "*_failed.csv" | wc -l

# 统计失败 CSV 数量
find results -name "*_failed.csv" | wc -l

# 查找错误文件
find results -name "abaqusError"

# 查找超时文件
find results -name "timeoutNote"
```

### 导出所有结果
```bash
# 合并所有 CSV 到单一文件
echo "File,Direction,L0,A0,K,YieldForce" > all_results.csv
for csv in $(find results -name "*.csv" ! -name "*_failed.csv"); do
    filename=$(basename $csv | sed 's/_E.*//')
    direction=$(basename $csv | grep -oE '_x\.csv|_y\.csv|_z\.csv' | tr -d '_.' )
    header=$(head -1 $csv)
    L0=$(echo $header | grep -oP 'L0=\K[0-9.]+')
    A0=$(echo $header | grep -oP 'A0=\K[0-9.]+')
    K=$(echo $header | grep -oP 'K=\K[0-9.]+')
    YieldForce=$(echo $header | grep -oP 'N=\K[0-9.]+')
    echo "$filename,$direction,$L0,$A0,$K,$YieldForce" >> all_results.csv
done
```

---

## 九、故障排查

### 常见问题

**1. 某些任务失败**
```bash
# 查看失败日志
grep -r "Error" slurm.logs/log_*.txt

# 查看错误文件
find results -name "abaqusError" -exec dirname {} \; | while read dir; do
    echo "=== $dir ==="
    cat $dir/*_failed.csv
done
```

**2. 任务超时**
```bash
# 增加超时时间（修改 sbatch.sh 第 4 行）
#SBATCH -t 72:00:00  # 72 小时

# 重新提交失败任务
find results -name "timeoutNote" -exec dirname {} \; | \
    sed 's|results/||' | cut -d'/' -f1 | sort -u > retry_tasks.txt
```

**3. 内存不足**
```bash
# 减少每个任务的 CPU 数（修改 cal_job 函数）
timeout $timelimit $roscript -i $path -o $outdirC -${direction} -n 1 ...
```

---

## 十、完整工作流程示例

```bash
# 1. 加载模块
module purge
module add abaqus/2022

# 2. 生成 tasks.txt
cd /public/home/nieqi01/zrx/20260310abq-pla/debug
python generate_tasks.py /public/data/step_models -o tasks.txt

# 3. 检查 tasks.txt
wc -l tasks.txt
head tasks.txt

# 4. 提交任务
sbatch sbatch.sh -i tasks.txt -o results -E 28700 -P 0.3 -Y 221.0

# 5. 监控进度
watch 'squeue -u $USER | grep plastic'

# 6. 检查结果
find results -name "*.csv" | wc -l

# 7. 导出结果
bash export_results.sh
```

---

## 十一、任务 ID 映射规则

对于 2000 个模型 × 3 方向 = 6000 任务，使用 1000 个 Array：

```bash
# 每个 Array 处理的任务数
tasks_per_array = ceil(6000 / 1000) = 6

# Array ID 与任务行的映射
Array 0  → tasks.txt 行 1-6
Array 1  → tasks.txt 行 7-12
Array 2  → tasks.txt 行 13-18
...
Array N  → tasks.txt 行 (N*6+1) 到 (N*6+6)

# 任务顺序（每 3 个完成一个模型的 xyz 方向）
行 1: model001.step x
行 2: model001.step y
行 3: model001.step z
行 4: model002.step x
行 5: model002.step y
行 6: model002.step z
```

这种分配确保：
- 每个 Array 处理约 6 个任务（2 个完整模型）
- 同一模型的 3 个方向尽可能在同一 Array 中
- 负载均衡，避免某些 Array 空闲
