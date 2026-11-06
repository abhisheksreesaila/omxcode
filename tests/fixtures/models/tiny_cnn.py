"""Small torch networks for scripts/packs/from_torch.py's own check (goal 59): one written from scratch (not torchvision),
using every kind of step the converter knows, and one it must refuse by name. Random weights (seed 0): the point is
that MAX gives what torch gives, not what the labels say."""
import torch
from torch import nn

LABELS = ["red", "green", "blue", "grey"]


class Tiny(nn.Module):
    def __init__(self):
        super().__init__()
        self.stem = nn.Sequential(nn.Conv2d(3, 16, 5, stride=2, padding=2, bias=False), nn.BatchNorm2d(16), nn.ReLU6())
        self.pool = nn.MaxPool2d(3, stride=2, padding=1)
        self.a = nn.Sequential(nn.Conv2d(16, 16, 3, padding=1), nn.BatchNorm2d(16), nn.SiLU())
        self.b = nn.Conv2d(16, 8, 1)
        self.c = nn.Sequential(nn.Conv2d(16, 8, 3, padding=1), nn.GELU())
        self.squash = nn.AvgPool2d(4, stride=4)
        self.drop = nn.Dropout(0.5)
        self.head = nn.Linear(16 * 4 * 4, len(LABELS))

    def forward(self, x):
        x = self.pool(self.stem(x))
        x = x + self.a(x)                                    # a residual add
        x = torch.cat([self.b(x), self.c(x)], dim=1)         # channels joined
        x = torch.sigmoid(x) * x                             # mul, a function call
        x = self.squash(x)                                   # 4 × 4 left: flatten's order matters
        return self.head(self.drop(torch.flatten(x, 1)))


class Unsupported(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv = nn.Conv2d(3, 8, 3, padding=1)
        self.up = nn.Upsample(scale_factor=2)

    def forward(self, x):
        return self.up(self.conv(x)).mean()


def tiny():
    torch.manual_seed(0)
    m = Tiny()
    for bn in (m.stem[1], m.a[1]):  # (BatchNorm's running statistics away from 0 and 1, so folding is really tested)
        bn.running_mean.uniform_(-0.5, 0.5)
        bn.running_var.uniform_(0.5, 2.0)
        bn.weight.data.uniform_(0.5, 1.5)
        bn.bias.data.uniform_(-0.2, 0.2)
    return m


def unsupported():
    torch.manual_seed(0)
    return Unsupported()
