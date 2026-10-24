# -*- coding: utf-8 -*-
"""无声调普通话拼音音节表（唯一真相源，与 Swift 的 SyllableTable.swift 保持同一集合）。

用途：
1. build_dict.py 用它做"词库拼音可切分性"校验（保证 Swift 端 DP 切分不会失败）；
2. 与 ios/Shared/IMECore/SyllableTable.swift 的 all 数组逐项对比（见 tools/dict/README.md 校验说明）。

约定：
- 全部小写、无声调；ü 统一写作 v（与 pypinyin 默认 Style.NORMAL 以及 iOS 键盘输入习惯一致）。
- 额外收录口语音节/叹词：n / ng / hm / hng / m / o / yo / lo / ê(e 的变体) 等，
  这些在 pypinyin 里可能被输出（例如"嗯"→n），必须有对应音节，否则切分失败。
"""

# 标准 410 音节（按声母分组，便于人工核对）
_STANDARD = """
a ai an ang ao
ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou
chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
da dai dan dang dao de dei deng di dia dian diao die ding diu dong dou du duan dui dun duo
e ei en eng er
fa fan fang fei fen feng fo fou fu
ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo
la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou
lu luan lue lun luo lv lve
ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou
nu nuan nue nun nuo nv nve
o ou
pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi
shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
wa wai wan wang wei wen weng wo wu
xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng
zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
"""

# 口语叹词 / 非标准但真实存在的音节（键盘上用户会打 nan/n/ng 之类）
_EXTRA = "n ng m hm hng ê ei o yo lo rua shei zhei dei tei den nen biang duang"

SYLLABLES = sorted(set(_STANDARD.split()) | set(_EXTRA.split()))

# 双拼/简拼常用首字母（仅用于文档说明；引擎从音节自动取首字母）
INITIALS = sorted({s[0] for s in SYLLABLES})

# 允许出现在拼音串里的字符（v 代表 ü）
PINYIN_LETTERS = "abcdefghijklmnopqrstuvwxyz"


def is_splittable(pinyin: str) -> bool:
    """用 DP 判断一个连写拼音串能否被音节表完整切分（与 Swift DP 同口径）。"""
    n = len(pinyin)
    if n == 0:
        return False
    reachable = [False] * (n + 1)
    reachable[0] = True
    max_len = 6
    for i in range(n):
        if not reachable[i]:
            continue
        for length in range(1, max_len + 1):
            j = i + length
            if j > n:
                break
            if pinyin[i:j] in _SET:
                reachable[j] = True
    return reachable[n]


_SET = frozenset(SYLLABLES)


if __name__ == "__main__":
    print("音节数:", len(SYLLABLES))
    print("首字母数:", len(INITIALS), INITIALS)
    for w in ("zhongguo", "nvhai", "lve", "zhongg", "xian", "n", "haode", "womendeyisheng"):
        print(w, "->", is_splittable(w))
