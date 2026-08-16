在开始维护项目前，请务必阅读README.md
如果遇到任何问题 或对用户设计有疑问，必须询问用户。
项目相关的文档:
- CC电脑: https://tweaked.cc/
- Tom's Peripherals: https://github.com/tom5454/Toms-Peripherals/wiki/

常见误区:
1.CC电脑的os.pullEvent()和os.queueEvent()会将事件分配给每一个消费者。多个消费者不会争抢事件
2.千万不要用lua原生携程，因为在原生携程中调用sleep()会导致携程直接退出
