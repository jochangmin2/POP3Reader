package com.xcurenet.pop3reader.service;

import com.xcurenet.pop3reader.config.MailProperties;
import com.xcurenet.pop3reader.model.MailData;
import lombok.RequiredArgsConstructor;
import lombok.extern.log4j.Log4j2;
import org.springframework.stereotype.Service;

import javax.mail.Folder;
import javax.mail.Message;
import javax.mail.Session;
import javax.mail.Store;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Date;

@Log4j2
@Service
@RequiredArgsConstructor
public class Pop3MailService {

	private final MailProperties mailProperties;
	private final MailFilterService mailFilterService;
	private final MailParserService mailParserService;
	private final MailForwardService mailForwardService;

	public void readAndProcess() {
		Store store = null;
		Folder inbox = null;

		try {
			Session session = Session.getInstance(mailProperties.getProperties());
			store = session.getStore("pop3");
			store.connect(mailProperties.getMailPop3Host(), mailProperties.getMailPop3Username(), mailProperties.getMailPop3Password());

			inbox = store.getFolder("INBOX");
			inbox.open(Folder.READ_ONLY);

			int total = inbox.getMessageCount();
			if (total == 0) return;

			int start = Math.max(1, total - mailProperties.getMailPop3FetchCount() + 1);
			Message[] messages = inbox.getMessages(start, total);

			Arrays.sort(messages, Comparator.comparing(this::safeSentDate).reversed());

			int count = 0;
			for (Message msg : messages) {
				if (count++ >= mailProperties.getMailPop3FetchCount()) break;
				if (!mailFilterService.isOriginalMail(msg)) {
					log.info("Skip mail: {}", msg.getSubject());
					continue;
				}

				MailData data = mailParserService.parse(msg, mailProperties.getMailPop3Username());
				mailForwardService.forward(data);
			}
		} catch (Exception e) {
			log.error("POP3 read error", e);
		} finally {
			close(inbox, store);
		}
	}

	private Date safeSentDate(Message m) {
		try {
			return m.getSentDate();
		} catch (Exception e) {
			return new Date(0);
		}
	}

	private void close(Folder inbox, Store store) {
		try {
			if (inbox != null && inbox.isOpen()) inbox.close(false);
			if (store != null) store.close();
		} catch (Exception ignored) {
		}
	}
}
